use v5.24.0;
use warnings;
package Synergy::Reactor::LiquidPlanner;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::ProvidesUserStatus',
     ;

use experimental qw(signatures lexical_subs);
use namespace::clean;
use Lingua::EN::Inflect qw(PL_N);
use List::Util qw(first sum0 uniq);
use Net::Async::HTTP;
use POSIX qw(ceil);
use JSON 2 ();
use Time::Duration;
use Time::Duration::Parse;
use Synergy::Logger '$Logger';
use Synergy::LPC; # LiquidPlanner Client, of course
use Synergy::LPC_F; # LiquidPlanner Client, with futures, of course
use Synergy::Timer;
use Synergy::Util qw(
  parse_time_hunk pick_one bool_from_text
  parse_switches
  canonicalize_names
);
use DateTime;
use DateTime::Format::ISO8601;

use utf8;

my $JSON = JSON->new->utf8;

my $TRIAGE_EMOJI = "\N{HELMET WITH WHITE CROSS}";

my $LINESEP = qr{(
  # space or newlines
  #   then, not a backslash
  #     then three dashes and maybe some leading spaces
  (^|\s+) (?<!\\) ---\s*
  |
  \n
)}nxs;

my sub _split_lines ($input, $n = -1) {
  my @lines = split /$LINESEP/, $input, $n;
  s/\\---/---/ for @lines;

  shift @lines while $lines[0] eq '';

  return @lines;
}

my sub parse_lp_datetime ($str) {
  DateTime::Format::ISO8601->parse_datetime($str);
}

has workspace_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has activity_id => (
  is  => 'ro',
  isa => 'Int',
);

has triage_channel_name => (
  is  => 'ro',
  isa => 'Str',
);

has triage_address => (
  is  => 'ro',
  isa => 'Str',
);

my $ERR_NO_LP = "You don't seem to be a LiquidPlanner-enabled user.";

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
}

sub _link_base_uri ($self) {
  return sprintf "https://app.liquidplanner.com/space/%s/projects/panel/",
    $self->workspace_id;
}

sub auth_header_for ($self, $user) {
  return unless my $token = $self->get_user_preference($user, 'api-token');

  if ($token =~ /-/) {
    return "Bearer $token";
  } else {
    return $token;
  }
}

sub item_uri ($self, $task_id) {
  return $self->_link_base_uri . $task_id;
}

sub _slack_item_link ($self, $item) {
  sprintf "<%s|LP>\N{THIN SPACE}%s",
    $self->item_uri($item->{id}),
    $item->{id};
}

my %Showable_Attribute = (
  shortcuts   => 1,
  phase       => 1,
  project     => 0,
  age         => 0,
  staleness   => 0,
  due         => 1,
  emoji       => 1,
  assignees   => 0,
  estimates   => 0,
  urgency     => 1,
  lastcomment => 0,

  escalation    => 0,
  stakeholders  => 0,
  # stuff we could make optional later:
  #   name
  #   type icon
  #   doneness
);

sub _is_urgent ($self, $item) {
  my $urgent = $self->urgent_package_id;
  scalar grep {; $_ == $urgent }
    ($item->{parent_ids}->@*, $item->{package_ids}->@*)
}

sub _last_comment_ago ($self, $item) {
  return unless $item->{comments} && $item->{comments}->@*;
  my ($latest) = sort { $a->{created_at} cmp $b->{created_at} }
                 $item->{comments}->@*;

  my $updated = parse_lp_datetime($latest->{updated_at});
  return concise(ago(time - $updated->epoch, 1));
}

sub _slack_item_link_with_name ($self, $item, $input_arg = undef) {
  my %arg = (
    %Showable_Attribute,
    ($input_arg ? %$input_arg : ()),
  );

  my $type  = $item->{type};
  my $title = $item->{name};

  if ($arg{shortcuts}) {
    state $shortcut_prefix = { Task => '*', Project => '#' };
    my $shortcut = $item->{custom_field_values}{"Synergy $type Shortcut"};
    $title .= " *\x{0200B}$shortcut_prefix->{$type}$shortcut*" if $shortcut;
  }

  if ( $arg{project}
    && $item->{project_id}
    && (grep {; $_ == $self->project_portfolio_id } $item->{parent_ids}->@*)
  ) {
    my $project = $item->{parent_crumbs}[-1] =~ s/^P: //r;
    $title = "*[$project]* $title";
  }

  if ($arg{phase} && (my $pstatus = $item->{custom_field_values}{"Project Phase"})) {
    $title =~ s/^(P:\s+)//n;
    $title = "*$pstatus:* $title";
  }

  my $emoji   = $item->{custom_field_values}{Emoji};
  my $bullet  = $item->{is_done}                                    ? "✓"
              : $arg{emoji} && $emoji                               ? $emoji
              : ($arg{urgency} && $item->{type} eq 'Task'
                               && $self->_is_urgent($item))         ? "🔥"
              :                                                       "•";

  my $text = sprintf "<%s|LP>\N{THIN SPACE}%s %s %s",
    $self->item_uri($item->{id}),
    $item->{id},
    $bullet,
    $title;

  if ($arg{due} && $item->{promise_by}) {
    my ($y, $m, $d) = split /-/, $item->{promise_by};
    state $month = [ qw(
      Nuluary
      January February  March
      April   May       June
      July    August    September
      October November  December
    ) ];

    my $str = $d >  20 ? 'late '
            : $d <= 10 ? 'early '
            :            'mid-';
    $str .= $month->[$m];

    my $now = DateTime->now;
    $str .= ", $y" unless $y == $now->year;

    $text .= " \N{EN DASH} due $str";
    $text .= " \N{CROSS MARK}" if $item->{promise_by} lt $now->ymd;
  }

  for my $field (qw(escalation stakeholders)) {
    if ($arg{$field} && (my $value = $item->{custom_field_values}{"\u$field"})) {
      $text .= " \N{EN DASH} $field: $value";
    }
  }

  if ($arg{assignees} || $arg{estimates}) {
    my %by_lp = map  {; $_->lp_id ? ($_->lp_id, $_->username) : () }
                $self->hub->user_directory->users;

    my $str = sub {
      my $str = $by_lp{ $_[0]{person_id} } // '?';
      return $str unless $arg{estimates};

      my ($high, $low) = $_[0]->@{ qw(high_effort_remaining low_effort_remaining )};
      return "$str (no estimate)" unless $high or $low;
      return sprintf "$str (%0.1fh-%0.1fh)", $low, $high;
    };


    my $want_done = $item->{is_done};
    my @assignees = map  {; $str->($_) }
                    grep {; $want_done || ! $_->{is_done} }
                    $item->{assignments}->@*;

    $text .= sprintf " \N{EN DASH} %s: %s",
      PL_N('assignees', 0+@assignees),
      (join q{, }, @assignees);
  }

  if ($arg{age}) {
    my $created = parse_lp_datetime($item->{created_at});
    $text .= " \N{EN DASH} created " .  concise(ago(time - $created->epoch, 1));
  }

  if ($arg{staleness}) {
    my $updated = parse_lp_datetime($item->{updated_at});
    $text .= " \N{EN DASH} updated " .  concise(ago(time - $updated->epoch, 1));
  }

  if ($arg{lastcomment}) {
    my $ago = $self->_last_comment_ago($item);
    $text .= " \N{EN DASH} " . ($ago ? "last comment $ago" : "no comments ever");
  }

  return $text;
}

has [ qw( inbox_package_id urgent_package_id project_portfolio_id recurring_package_id ) ] => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

my %KNOWN = (
  # SHORTCUTS
  '++'      =>  [ \&_handle_plus_plus,
                  "++ TASK: short for `task for me: TASK`, so see `help task`"],
  '<<'      =>  [ \&_handle_angle_angle ], # To Neil, with love.
  '>>'      =>  [ \&_handle_angle_angle,
                  ">> PERSON REST: short for `task for PERSON: REST`, so see `help task`"],

  # TIMER COMMANDS
  timer     =>  [ \&_handle_timer,
    <<'EOH' =~ s/\b\n([^\s•])/ $1/rg
The *timer* command lets you manage your LiquidPlanner timer.  With no further
arguments, it just tells you whether you've got a timer and, if so, the timer's
task and running time.

These further commands exist for controlling your timer:

• *timer abort*: throw your timer away
• *timer commit `COMMENT`*: commit your timer, with optional comment
• *timer done*: commit your timer and mark your work done
• *timer reset*: set your timer back to zero, but leave it running
• *timer resume*: restart the last timer you had running again
• *timer start `TASK`*: start your timer on the given task
• *timer stop*: stop your timer, but keep the time on it

*timer commit* is notable because you can end your comment with a few magic
words to take extra actions, like:

• *DONE*: mark your work on this task done
• *STOP*: stop the timer when committing; by default, it will keep running
• *CHILL*: stop the timer and don't nag until you're active again
• *TIME `Xh`*: override the time on the timer, and commit X h(ours) or m(inutes) instead
EOH
                ],
  abort     =>  [ \&_handle_timer_abort  ],
  commit    =>  [ \&_handle_timer_commit ],
  done      =>  [ \&_handle_timer_done   ],
  reset     =>  [ \&_handle_timer_reset  ],
  restart   =>  [ \&_handle_timer_resume ],
  resume    =>  [ \&_handle_timer_resume ],
  start     =>  [ \&_handle_timer_start  ],
  stop      =>  [ \&_handle_timer_stop   ],

  # AVAILABILITY COMMANDS
  chill     =>  [ \&_handle_chill,
                  "chill: do not nag about a timer until you say something new",
                  "chill until WHEN: do not nag until the designated time",
                  ],
  expand    =>  [ \&_handle_expand ],
  shows     =>  [ \&_handle_shows,       ],
  "show's"  =>  [ \&_handle_shows,       ],
  showtime  =>  [ \&_handle_showtime,    ],
  zzz       =>  [ \&_handle_triple_zed,  ],

  # SILLY NONSENSE
  good      =>  [ \&_handle_good   ],
  gruß      =>  [ \&_handle_good   ],

  # MISCELLANEOUS STUFF
  iteration =>  [ \&_handle_iteration,
                  "iteration: show details of the current iteration",
                  "iteration ±N: show the iteration N before or after this one",
                  "iteration N: show the iteration numbered N",
                ],
  last      =>  [ \&_handle_last   ],

  # SEARCH AND REPORT COMMANDS
  search    =>  [
    \&_handle_search,
    join("\n",
      "*search `SEARCH`*: find items in LiquidPlanner matching term",
      "Additional search fields include:",
      "• *done:`{yes,no,both}`*, search for completed items",
      "• *in:`{inbox,urgent,recurring,LP-ID}`*, search for scheduled items",
      "• *onhold:`{yes,no,both}`*, search for items on hold",
      "• *page:`N`*, get the Nth page of 10 results",
      "• *phase:`P`*, only find work in projects in phase P",
      "• *project:`PROJECT`*, search in this project shortcut",
      "• *scheduled:`{yes,no,both}`*, search for scheduled items",
      "• *type:`TYPE`*, pick what type of items to find (package, project, task)",
      "• *tags:`TAG`*, find items with the given tag",
      "• *o[wner]:`USER`*, items owned by the named user",
      "• *creator:`USER`*, items created by the named user",
      "• *created:`{before,after}`:`YYYY-MM-DD`*, items created in the time range",
      "• *lastupdated:`{before,after}`:`YYYY-MM-DD`*, items last updated in the time range",
      "• *client:`NAME`*, find items with the given client",
      "• *escalation:`USER`*, items with the user NAME as escalation point (*~* for unset)",
      "• *stakeholder:`USER`*, items where named user is a stakeholder",
      "• *shortcut:`~`*, items without shortcuts (must also use *type*)",
      "• *shortcut:`*`*, items with shortcuts (must also use *type*)",
      "• *force:`1`*, search even if Synergy says it's too broad",
      "• *debug:`1`*, turn on debugging and dump the query to be run",
      "",
      "You can also say *show:`FIELD`* or *show:`FIELD`:`{yes,no}`* to toggle what fields are displayed.",
      "The available fields include:",
      "",
      "• *age*: how long ago the item was created",
      "• *assignees*: who has undone assignments on the item",
      "• *due*: when the item is expected to be complete",
      "• *emoji*: the custom emoji for projects that have one",
      "• *estimates*: the estimates on undone assignments",
      "• *lastcomment*: how long since the last comment on the item",
      "• *phase*: the project phase on projects",
      "• *project*: show an item's containing project",
      "• *shortcuts*: item shortcuts, if defined",
      "• *staleness*: how long since the last update to the item",
      "• *urgency*: note when items are urgent",
    ),
  ],

  psearch    =>  [
    \&_handle_psearch,
    "just like search, but with an implicit *type:project*",
  ],

  tsearch    =>  [
    \&_handle_tsearch,
    "just like search, but with an implicit *type:task*",
  ],

  inbox     =>  [ \&_handle_inbox,
                  "inbox [PAGE-NUMBER]: list the tasks in your inbox",
                ],

  projects  =>  [ \&_handle_projects,
                  "projects: list all known project shortcuts",
                ],
  recurring =>  [ \&_handle_recurring,
                  "recurring [PAGE-NUMBER]: list your tasks in Recurring Tasks",
                ],
  triage    =>  [ \&_handle_triage,
                  "triage [PAGE-NUMBER]: list the tasks awaiting triage",
                ],
  urgent    =>  [ \&_handle_urgent,
                  "urgent [PAGE-NUMBER]: list your urgent tasks",
                ],
  tasks     =>  [ \&_handle_tasks,
                  "tasks [PAGE-NUMBER]: list your scheduled work",
                ],

  # TODO LISTS -- Can we remove this? -- rjbs, 2019-07-02
  todo      =>  [ \&_handle_todo,        ],
  todos     =>  [ \&_handle_todos,       ],

  # TASK CREATION AND MANAGEMENT
  spent     =>  [ \&_handle_spent,
                  "spent TIME on THING: log time against a task (either TASK-SPEC or TASK-ID)",
                ],

  task      =>  [
    \&_handle_task,
    <<'EOH' =~ s/\b\n\b/ /rg
*task for `USER`: `NAME`*: create a new task in LiquidPlanner

In the simplest form, this creates a new task with the given name, assigned to
the given user.  (You can also give multiple users, separated by commas, for
the `USER`.)  More information can be provided on new lines, or split up by
triple dashes (`---`).  Every new line that start with a `/` is taken as a
series of slash commands, documented below.  After those slash command lines,
the rest of the lines are taken as the long description for the task.

The slash commands understood are:
* */assign `USER`*: assign one or more users to the task
* */done*: mark the task done immediately on creation
* */estimate `X`-`Y`*: give all assignments on the task an estimate of X-Y
* */log `TIME`*: log the given amount of time spent (by you) on the task
* */project*: create the task in the named project (see *projects*)
* */start*: start your timer running on this task
* */urgent*: mark this task as urgent
EOH
  ],

  comment   =>  [ \&_handle_comment,
                  "comment on THING: comment on a LiquidPlanner task, project, or whatever",
                ],

  contents  =>  [ \&_handle_contents,
                  "contents CONTAINER: show what's in a package or project",
                ],

  update    =>  [ \&_handle_update,      ],
);

sub listener_specs {
  return (
    {
      name      => "you're-back",
      method    => 'see_if_back',
      predicate => sub { 1 },
    },
    {
      name      => "lookup-events",
      method    => "dispatch_event",
      exclusive => 1,
      predicate => sub ($self, $event) {
        return unless $event->type eq 'message';
        return unless $event->was_targeted;

        my ($what) = $event->text =~ /^(\S+)(?: \z | \s)/x;
        $what &&= lc $what;

        return 1 if $KNOWN{$what};
        return 1 if $what =~ /^g'day/;    # stupid, but effective
        return 1 if $what =~ /^goo+d/;    # Adrian Cronauer
        return 1 if $what =~ /^done,/;    # ugh
        return 1 if $what =~ /^show’s/;   # ugh, curly quote
        return;
      },
      help_entries => [
        map {;
          my $key = $_;
          my @things = $KNOWN{$key}->@*;
          shift @things;
          map {; { title => $key, text => $_ } } @things;
        } keys %KNOWN
      ]
    },
    {
      name      => "reload-clients",
      method    => "reload_clients",
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted &&
        $e->text =~ /^reload\s+clients\s*$/i;
      },
    },
    {
      name      => "reload-shortcuts",
      method    => "reload_shortcuts",
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted &&
        $e->text =~ /^reload\s+shortcuts\s*$/i;
      },
    },
    {
      name      => "lp-mention-in-passing",
      method    => "provide_lp_link",
      predicate => sub { 1 },
    },
    {
      name      => "last-thing-said",
      method    => 'record_utterance',
      predicate => sub { 1 },
    },
  );
}

sub dispatch_event ($self, $event) {
  unless ($event->from_user) {
    $event->error_reply("Sorry, I don't know who you are.");
    $event->mark_handled;
    return 1;
  }

  # existing hacks for massaging text
  my $text = $event->text;

  $text =~ s/\Ashow’s\b/show's/i; # curly quote
  $text = "good day_au" if $text =~ /\A\s*g['’]day(?:,?\s+mate)?[1!.?]*\z/i;
  $text = "good day_de" if $text =~ /\Agruß gott[1!.]?\z/i;
  $text =~ s/\Ago{3,}d(?=\s)/good/;
  $text =~  s/^done, /done /;   # ugh

  my ($what, $rest) = split /\s+/, $text, 2;
  $what &&= lc $what;

  # we can be polite even to non-lp-enabled users
  return $self->_handle_good($event, $rest) if $what eq 'good';

  unless ($self->auth_header_for($event->from_user)) {
    $event->mark_handled;
    $event->error_reply($ERR_NO_LP);
    return 1;
  }

  $event->mark_handled;
  my $handler = $KNOWN{$what}[0];
  $Logger->log("IMPOSSIBLE: no handler for $what?") unless $handler;

  return $self->$handler($event, $rest)
}

sub provide_lp_link ($self, $event) {
  my $user = $event->from_user;
  return unless $user && $self->auth_header_for($user);

  state $lp_id_re       = qr/\bLP\s*([1-9][0-9]{5,10})\b/i;
  state $lp_shortcut_re = qr/\bLP\s*([*#][-_a-z0-9]+)\b/i;

  # This is a stupid hack to replace later. -- rjbs, 2019-02-22
  state $lp_flags = qr{\/desc(?:ription)?};

  my $workspace_id  = $self->workspace_id;
  my $lp_url_re     = qr{\b(?:\Qhttps://app.liquidplanner.com/space/$workspace_id\E/.*/)([0-9]+)P?/?\b};

  my $lpc = $self->f_lp_client_for_user($user);
  my $item_id;

  my $as_cmd;

  my %flag;
  if (
    $event->was_targeted
    && ($event->text =~ /\A\s* $lp_id_re        (?<flag>\s+$lp_flags)? \s*\z/x
    ||  $event->text =~ /\A\s* $lp_shortcut_re  (?<flag>\s+$lp_flags)? \s*\z/x
    ||  $event->text =~ /\A\s* $lp_url_re       (?<flag>\s+$lp_flags)? \s*\z/x)
  ) {
    $flag{description} = 1 if $+{flag};

    # do better than bort
    $event->mark_handled;

    $as_cmd = 1;
  }

  my @ids = $event->text =~ /$lp_id_re/g;
  push @ids, $event->text =~ /$lp_url_re/g;

  my @shortcuts = $event->text =~ /$lp_shortcut_re/g;
  for my $shortcut (@shortcuts) {
    my $method = ((substr $shortcut, 0, 1, q{}) eq '*' ? 'task' : 'project')
               . '_for_shortcut';

    my ($item, $error)  = $self->$method($shortcut);
    return $event->error_reply($error) unless $item;

    push @ids, $item->{id};
  }

  return unless @ids;

  ITEM: for my $item_id (@ids) {
    $lpc
      ->get_item($item_id)
      ->else(sub {
        $event->reply("Sorry, something went wrong looking for LP$item_id.");
        return Future->done;
      })
      ->then(sub ($item) {
        unless ($item) {
          $event->error_reply("I can't find anything for LP$item_id.");
          return Future->done;
        }

        my $name = $item->{name};

        my $reply;

        if ($item->{type} =~ /\A Task | Package | Project | Folder \z/x) {
          my $icon = $item->{custom_field_values}{Emoji}
                  // ($item->{type} eq 'Task'    ? ($as_cmd ? "🌀" : "")
                    : $item->{type} eq 'Package' ? "📦"
                    : $item->{type} eq 'Project' ? "📁"
                    : $item->{type} eq 'Folder'  ? "🗂"
                    : $item->{type} eq 'Inbox'   ? "📫"
                    :                              confess("unreachable"));

          my $uri = $self->item_uri($item_id);

          my $plain = "$icon LP$item_id: $item->{name} ($uri)";
          my $slack = sprintf '%s %s',
            $icon,
            $self->_slack_item_link_with_name($item, { emoji => 0 });

          if ($as_cmd) {
            my %by_lp = map {; $_->lp_id ? ($_->lp_id, $_->username) : () }
                        $self->hub->user_directory->users;

            # The user asked for this directly, so let's give them more detail.
            $slack .= "\n";

            if ($item->{parent_crumbs}) {
              $slack .= "*Parent*: "
                     .  (join(q{ >> }, $item->{parent_crumbs}->@*) || "(?)")
                     .  "\n";
            }

            if ($item->{package_crumbs}) {
              $slack .= "*Package*: "
                     .  (join(q{ >> }, $item->{package_crumbs}->@*) || "(?)")
                     .  "\n";
            }

            if ($item->{custom_field_values}{Escalation}) {
              $slack .= "*Escalation Point*: $item->{custom_field_values}{Escalation}\n";
            }

            if ($item->{assignments}) {
              my @assignees = sort uniq
                              map  {; $by_lp{ $_->{person_id} } // '?' }
                              grep {; ! $_->{is_done} }
                              $item->{assignments}->@*;

              if (@assignees && $item->{type} eq 'Project') {
                $slack .= "*Project Lead*: " . shift(@assignees) . "\n";
              }

              if (@assignees) {
                $slack .= "*Assignees*: " . join(q{, }, @assignees) . "\n";
              }
            }

            if ($item->{custom_field_values}{Stakeholders}) {
              $slack .= sprintf "*Stakeholders*: %s\n",
                join q{, },
                sort
                split /\s*,\s*/, $item->{custom_field_values}{Stakeholders};
            }

            for my $pair (
              [ 'Created',      'created_at' ],
              [ 'Last updated', 'updated_at' ],
              [ 'Completed',    'done_on' ],
            ) {
              next unless my $date_str = $item->{ $pair->[1] };

              my $dt = DateTime::Format::ISO8601->parse_datetime($date_str);

              my $str = $self->hub->format_friendly_date(
                $dt,
                {
                  target_time_zone  => $event->from_user->time_zone,
                }
              );

              $slack .= "*$pair->[0]*: $str\n";
            }

            if ($flag{description}) {
              $slack .= "\n>>> "
                      . ($item->{description} // "(no description)")
                      . "\n";
            }

            if ($item->{comments}) {
              my ($latest) = sort {; $b->{created_at} cmp $a->{created_at} }
                             $item->{comments}->@*;

              my %by_lp = map  {; $_->lp_id ? ($_->lp_id, $_->username) : () }
                          $self->hub->user_directory->users;

              if ($latest) {
                my $created = parse_lp_datetime($latest->{created_at});

                $slack .= sprintf "\n*Last comment* by %s, %s:\n>>> %s\n",
                  $by_lp{ $latest->{person_id} } // 'somebody',
                  concise(ago(time - $created->epoch, 1)),
                  $latest->{plain_text};
              }
            }
          }

          return $event->reply(
            $plain,
            {
              slack => $slack,
            },
          );
        } else {
          $event->reply("LP$item_id: is a $item->{type}");
        }
      })->retain;
  }
}

has _last_lp_timer_task_ids => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
  writer => '_set_last_lp_timer_task_ids',
);

sub set_last_lp_timer_task_id_for_user ($self, $user, $task_id) {
  $self->_last_lp_timer_task_ids->{ $user->username } = $task_id;

  $self->save_state;
}

sub last_lp_timer_task_id_for_user ($self, $user) {
  return unless $self->auth_header_for($user);
  return $self->_last_lp_timer_task_ids->{ $user->username };
}

has user_timers => (
  is               => 'ro',
  isa              => 'HashRef',
  traits           => [ 'Hash' ],
  lazy             => 1,
  handles          => {
    _timer_for_user     => 'get',
    _add_timer_for_user => 'set',
  },

  default => sub { {} },
);

sub state ($self) {
  my $timers = $self->user_timers;
  my $last_timer_ids = $self->_last_lp_timer_task_ids;
  my $prefs = $self->user_preferences;

  return {
    user_timers => {
      map {; $_ => $timers->{$_}->as_hash }
        keys $self->user_timers->%*
    },
    last_timer_ids => $last_timer_ids,
    preferences    => $prefs,
  };
}

sub timer_for_user ($self, $user) {
  return unless $self->user_has_preference($user, 'api-token');

  my $timer = $self->_timer_for_user($user->username);

  if ($timer) {
    # This is a bit daft, but otherwise we could initialize the cached timer
    # before the user's time zone has loaded from GitHub.  Then we'd be stuck
    # with it.  Doing this update is cheap. -- rjbs, 2018-04-16
    $timer->time_zone($user->time_zone);

    # equally daft -- michael, 2018-04-17
    $timer->business_hours($user->business_hours);

    return $timer;
  }

  $timer = Synergy::Timer->new({
    time_zone      => $user->time_zone,
    business_hours => $user->business_hours,
  });

  $self->_add_timer_for_user($user->username, $timer);

  $self->save_state;

  return $timer;
}

has primary_nag_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has aggressive_nag_channel_name => (
  is => 'ro',
  isa => 'Str',
  default => 'twilio',
);

has last_utterances => (
  isa       => 'HashRef',
  init_arg  => undef,
  default   => sub {  {}  },
  traits    => [ 'Hash' ],
  handles   => {
    set_last_utterance => 'set',
    get_last_utterance => 'get',
  },
);

sub record_utterance ($self, $event) {
  # We're not going to support "++ that" by people who are not users.
  return unless $event->from_user;

  if ($event->text =~ /^last$/i) {
    return;
  }

  $self->set_last_utterance($event->source_identifier, $event->text);

  return;
}

sub see_if_back ($self, $event) {
  # We're not going to support "++ that" by people who are not users.
  return unless $event->from_user;

  my $timer = $self->timer_for_user($event->from_user) || return;

  my $lpc = $self->lp_client_for_user($event->from_user);
  my $timer_res = $lpc->my_running_timer;

  if ($timer->chill_until_active
    and $event->text !~ /\bzzz\b/i
  ) {
    $Logger->log([
      '%s is back; ending chill_until_active',
      $event->from_user->username,
    ]);
    $timer->chill_until_active(0);
    $timer->clear_chilltill;
    $self->save_state;
    $event->ephemeral_reply("You're back!  No longer chilling.")
      if $timer->is_business_hours and $timer_res->is_nil;
  }
}

has projects => (
  isa => 'HashRef',
  traits => [ 'Hash' ],
  handles => {
    project_shortcuts     => 'keys',
    _project_by_shortcut  => 'get',
  },
  lazy => 1,
  default => sub ($self) {
    $self->get_project_shortcuts;
  },
  writer    => '_set_projects',
);

has tasks => (
  isa => 'HashRef',
  traits => [ 'Hash' ],
  handles => {
    task_shortcuts     => 'keys',
    _task_by_shortcut => 'get',
  },
  lazy => 1,
  default => sub ($self) {
    $self->get_task_shortcuts;
  },
  writer    => '_set_tasks',
);

has clients => (
  lazy    => 1,
  isa     => 'HashRef',
  traits  => [ 'Hash' ],
  handles => {
    clients => 'values',
    client_named => 'get',
  },
  clearer => '_clear_clients',
  default => sub ($self) {
    my $lpc = $self->lp_client_for_master;
    my $clients_res = $lpc->get_clients;
    return {} unless $clients_res->is_success;

    return { map {; lc $_->{name} => $_ } $clients_res->payload_list };
  }
);

sub reload_clients ($self, $event) {
  $self->_clear_clients;
  my $clients = $self->clients;

  $event->mark_handled;
  if (%$clients) {
    $event->reply("Client list reloaded.");
  } else {
    $event->reply("There was a problem reloading the LiquidPlanner client list.  Now that list is empty.  Oops.");
  }
}

sub _item_for_shortcut ($self, $thing, $shortcut) {
  my $getter = "_$thing\_by_shortcut";
  my $things = $self->$getter(fc $shortcut);

  unless ($things && @$things) {
    return (0, qq{Sorry, I don't know a $thing with the shortcut "$shortcut".});
  }

  if (@$things > 1) {
    return (0, qq{More than one LiquidPlanner $thing has the shortcut }
             . qq{"$shortcut".  Their ids are: }
             . join(q{, }, map {; $_->{id} } @$things));
  }

  return ($things->[0], undef);
}

sub project_for_shortcut ($self, $shortcut) {
  $self->_item_for_shortcut(project => $shortcut);
}

sub task_for_shortcut ($self, $shortcut) {
  $self->_item_for_shortcut(task => $shortcut);
}

sub start ($self) {
  my $timer = IO::Async::Timer::Periodic->new(
    interval => 300,
    on_tick  => sub ($timer, @arg) { $self->nag($timer); },
  );

  $self->hub->loop->add($timer);

  $timer->start;
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {

    # Must load these first, otherwise timer_for_user will return
    # undef since user won't have an api-token...
    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }

    if (my $timer_state = $state->{user_timers}) {
      for my $username (keys %$timer_state) {
        next unless my $user = $self->hub->user_directory
                                         ->user_named($username);

        next unless my $timer = $self->timer_for_user($user);

        my $this_timer = $timer_state->{$username};

        my $chill_type = $this_timer->{chill}{type} // '';
        if ($chill_type eq 'until_active') {
          $timer->chill_until_active(1);
        } elsif ($chill_type eq 'until_time') {
          $timer->chilltill( $this_timer->{chill}{until} );
        }
      }
    }

    if (my $last_timer_ids = $state->{last_timer_ids}) {
      $self->_set_last_lp_timer_task_ids($last_timer_ids);
    }


    $self->save_state;
  }
};

sub _user_doing_dnd ($self, $user) {
  my (@statuses) = map  {; $_->doings_for_user($user) }
                   grep {; $_->does('Synergy::Reactor::Status') }
                   $self->hub->reactors;

  return !! grep { $_->{dnd} } @statuses;
}

sub nag ($self, $timer, @) {
  $Logger->log("considering nagging");

  USER: for my $user ($self->hub->user_directory->users) {
    next USER unless my $sy_timer = $self->timer_for_user($user);

    next USER unless $self->get_user_preference($user, 'should-nag');

    my $username = $user->username;

    my $last_nag = $sy_timer->last_relevant_nag;
    my $lp_timer = $self->lp_timer_for_user($user);

    if ($lp_timer && $lp_timer == -1) {
      $Logger->log("$username: error retrieving timer");
      next USER;
    }

    # Record the last time we saw a timer
    if ($lp_timer) {
      $sy_timer->last_saw_timer(time);
    }

    { # Timer running too long!
      if ($lp_timer && $lp_timer->running_time > 3) {
        if ($last_nag && time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }

        my $msg = "Your timer has been running for "
                . $lp_timer->running_time_duration
                . ".  Maybe you should commit your work.";

        my $friendly = $self->hub->channel_named($self->primary_nag_channel_name);
        $friendly->send_message_to_user($user, $msg);

        if ($user) {
          my $aggressive = $self->hub->channel_named($self->aggressive_nag_channel_name);
          $aggressive->send_message_to_user($user, $msg);
        }

        $sy_timer->last_nag({ time => time, level => 0 });
        next USER;
      }
    }

    my $showtime = $sy_timer->is_showtime;
    my $user_dnd = $self->_user_doing_dnd($user);
    my $til = $sy_timer->chilltill;
    $Logger->log([
      "nag status for %s: %s",
      $username,
      { showtime => $showtime, dnd => $user_dnd, chilltill => $til }
    ]);

    if ($showtime && ! $user_dnd) {
      if ($lp_timer) {
        $Logger->log("$username: We're good: there's a timer.");

        $sy_timer->clear_last_nag;
        next USER;
      }

      my $level = 0;
      if ($last_nag) {
        if (time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }
        $level = $last_nag->{level} + 1;
      }

      # Have we seen a timer recently? Give them a grace period
      if (
           $sy_timer->last_saw_timer
        && $sy_timer->last_saw_timer > time - 900
      ) {
        $Logger->log([
          "not nagging %s, they only recently disabled a timer",
          $username,
        ]);
        next USER;
      }

      my $still = $level == 0 ? '' : ' still';
      my $msg   = "Your LiquidPlanner timer$still isn't running";
      $Logger->log([ 'nagging %s at level %s', $user->username, $level ]);
      my $friendly = $self->hub->channel_named($self->primary_nag_channel_name);
      $friendly->send_message_to_user($user, $msg);
      if ($level >= 2) {
        my $aggressive = $self->hub->channel_named($self->aggressive_nag_channel_name);
        $aggressive->send_message_to_user($user, $msg);
      }
      $sy_timer->last_nag({ time => time, level => $level });
    }
  }
}

sub _get_treeitem_shortcuts {
  my ($self, $type) = @_;

  my $lpc = $self->f_lp_client_for_master;
  my $res = $lpc->query_items({
    filters => [
      [ item_type => '='  => $type    ],
      [ is_done   => is   => 'false'  ],
      [ "custom_field:'Synergy $type Shortcut'" => 'is_set' ],
    ],
  });

  return {} unless $res->block_until_ready->is_done;

  my %dict;
  my %seen;

  for my $item ($res->get->@*) {
    # Impossible, right?
    next unless my $shortcut = $item->{custom_field_values}{"Synergy $type Shortcut"};

    # Because of is_packaged_version field leading to dupes. -- rjbs 2018-07-05
    next if $seen{ $item->{id} }++;

    # We'll deal with conflicts later. -- rjbs, 2018-01-22
    $dict{ lc $shortcut } //= [];

    # But don't add the same project twice. -- michael, 2018-04-24
    my @existing = grep {; $_->{id} eq $item->{id} } $dict{ lc $shortcut }->@*;
    if (@existing) {
      $Logger->log([
        qq{Duplicate %s %s found; got %s, conflicts with %s},
        "\l$type",
        $shortcut,
        $item->{id},
        [ map {; $_->{id} } @existing ],
      ]);
      next;
    }

    $item->{shortcut} = $shortcut; # needed?
    push $dict{ lc $shortcut }->@*, $item;
  }

  return \%dict;
}

sub get_project_shortcuts ($self) { $self->_get_treeitem_shortcuts('Project') }
sub get_task_shortcuts    ($self) { $self->_get_treeitem_shortcuts('Task') }

sub _lp_client_for_user ($self, $class, $user) {
  $class->new({
    auth_token    => $self->auth_header_for($user),
    workspace_id  => $self->workspace_id,
    logger_callback   => sub { $Logger },

    ($self->activity_id ? (single_activity_id => $self->activity_id) : ()),

    http_get_callback => sub ($, $uri, @arg) {
      $self->hub->http_get($uri, @arg);
    },
    http_post_callback => sub ($, $uri, @arg) {
      $self->hub->http_post($uri, @arg);
    },
  });
}

sub lp_client_for_user ($self, $user) {
  $self->_lp_client_for_user('Synergy::LPC', $user);
}

sub f_lp_client_for_user ($self, $user) {
  $self->_lp_client_for_user('Synergy::LPC_F', $user);
}

sub lp_client_for_master ($self) {
  my ($master) = $self->hub->user_directory->master_users;

  Carp::confess("No master users configured") unless $master;

  $self->lp_client_for_user($master);
}

sub f_lp_client_for_master ($self) {
  my ($master) = $self->hub->user_directory->master_users;

  Carp::confess("No master users configured") unless $master;

  $self->f_lp_client_for_user($master);
}

sub _handle_last ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->error_reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  return if length $text;

  $event->mark_handled;

  if (my $last = $self->get_last_utterance(
    $event->source_identifier
  )) {
    $event->reply("The last thing you said here was: $last");
  } else {
    $event->reply("You haven't said anything here yet that I've seen (ignoring 'last')");
  }
}

sub _extract_flags_from_task_text ($self, $text) {
  my %flag;

  my $start_emoji
    = qr{ ⏲   | ⏳  | ⌛️  | :hourglass(_flowing_sand)?: | :timer_clock: }nx;

  my $urgent_emoji
    = qr{ ❗️  | ‼️   | ❣️   | :exclamation: | :heavy_exclamation_mark:
                          | :heavy_heart_exclamation_mark_ornament:
        | 🔥              | :fire: }nx;

  while ($text =~ s/\s*\(([!>]+)\)\s*\z//
     ||  $text =~ s/\s*($start_emoji|$urgent_emoji)\s*\z//
     ||  $text =~ s/\s+(#[a-z0-9]+)\s*\z//i
  ) {
    my $hunk = $1;
    if ($hunk =~ s/^#//) {
      $flag{project}{$hunk} = 1;
      next;
    } elsif ($hunk =~ /[!>]/) {
      $flag{start} ++                               if $hunk =~ />/;
      $flag{package}{ $self->urgent_package_id } ++ if $hunk =~ /!/;
      next;
    } else {
      $flag{start} ++                               if $hunk =~ $start_emoji;
      $flag{package}{ $self->urgent_package_id } ++ if $urgent_emoji;
      next;
    }
  }

  return (
    $text,
    %flag,
  );
}

sub _check_plan_project ($self, $event, $plan, $error) {
  my $project = delete $plan->{project};

  if (keys %$project > 1) {
    $error->{project} = "More than one project specified!";
    return;
  }

  my ($project_name) = keys %$project;
  my ($item, $err) = $self->project_for_shortcut($project_name);

  if ($item) {
    $plan->{project_id} = $item->{id};
  } else {
    $error->{project} = $err;
  }

  return;
}

sub _check_plan_package ($self, $event, $plan, $error) {
  my $package = delete $plan->{package};

  return unless keys %$package;

  if (keys %$package > 1) {
    $error->{package} = "More than one package specified!";
    return;
  }

  ($plan->{package_id}) = keys %$package;

  return;
}

sub _check_plan_usernames ($self, $event, $plan, $error) {
  my $usernames = delete $plan->{usernames};

  my (@owners, @no_lp, @unknown);
  my %seen;

  my %project_id;
  for my $username (@$usernames) {
    my $target = $self->resolve_name($username, $event->from_user);

    next if $target && $seen{ $target->username }++;

    my $owner_id = $target ? $target->lp_id : undef;

    if ($owner_id) {
      push @owners, $target;
    } elsif ($target) {
      push @no_lp, $target->username;
    } else {
      push @unknown, $username;
    }
  }

  if (@unknown or @no_lp) {
    my @fail;

    if (@unknown) {
      my $str = @unknown == 1 ? "$unknown[0] is"
              : @unknown == 2 ? "$unknown[0] or $unknown[1] are"
              : join(q{, }, @unknown[0 .. $#unknown-1], "or $unknown[-1] are");
      push @fail, "I don't know who $str.";
    }

    if (@no_lp) {
      my $str = @no_lp == 1 ? $no_lp[0]
              : @no_lp == 2 ? "$no_lp[0] or $no_lp[1]"
              : join(q{, }, @no_lp[0 .. $#no_lp-1], "or $no_lp[-1]");
      push @fail, "There's no LiquidPlanner user for $str.";
    }

    $error->{usernames} = join q{  }, @fail;
    return;
  }

  if ($plan->{package}{urgent}) {
    if (my @virtuals = grep {; $_->is_virtual } @owners) {
      my $names = join q{, }, sort map {; $_->username } @virtuals;
      $error->{usernames}
        = "Sorry, you can't make urgent tasks for non-humans."
        . "  Find a human who can take responsibility, even if it's you."
        . "  You got this error because you tried to assign an urgent task to:"
        . " $names";
    }
  }

  unless ($plan->{project}) {
    my @projects  = uniq
                    grep { defined }
                    map  {; $self->get_user_preference($_, 'default-project-shortcut') }
                    @owners;

    if (@projects == 1) {
      $plan->{project}{ $projects[0] } = 1;
    }
  }

  $plan->{owners} = \@owners;
  return;
}

sub _check_plan_rest ($self, $event, $plan, $error) {
  my $via = $event->description;
  my $uri = $event->event_uri;

  my $rest = delete $plan->{rest};

  my @cmd_lines;

  if ($rest) {
    my @lines = _split_lines($rest);
    push @cmd_lines, shift @lines while @lines && $lines[0] =~ m{\A/};
    my $cmd_line = join q{ }, @cmd_lines;
    $rest = join qq{\n}, @lines;

    my ($ok, $subcmd_error) = $self->_handle_subcmds('create', $cmd_line, $plan);

    unless ($ok) {
      $error->{rest} = $subcmd_error // "Error with subcommands.";
      return;
    }
  }

  # make ticket nums easier to copy
  $rest =~ s/\b(ptn)([0-9]+)\b/$1 $2/gi if $rest;

  $plan->{description} = sprintf '%screated by %s in response to %s%s',
    ($rest ? "$rest\n\n" : ""),
    $self->hub->name,
    $via,
    $uri ? "\n\n$uri" : "";
}

sub _handle_subcmds ($self, $phase, $cmd_line, $plan) {
  # TODO: make this less slapdash -- rjbs, 2018-06-08
  my @errors;
  my @bad_cmds;

  my %alias = (
    a   => 'assign',
    d   => 'done',
    e   => 'estimate',
    go  => 'start',
    l   => 'log',
    p   => 'project',
    s   => 'start',
    u   => 'urgent',
  );

  my %error;

  my ($switches, $error) = parse_switches($cmd_line);
  push @errors, $error if $error and ! grep {; $_ eq $error } @errors;

  canonicalize_names($switches, \%alias);

  my sub cmd_error ($str) {
    no warnings 'exiting';
    $error{$str} = 1;
    next CMD;
  }

  CMD: for my $switch (@$switches) {
    # So far, all switches take a list of strings to concatenate.  That won't
    # always be the case, and we'll refactor when we get there.
    # -- rjbs, 2019-06-21
    my ($cmd, @args) = @$switch;

    if ($cmd eq 'urgent') {
      cmd_error("The /urgent command takes no arguments.") if @args;

      my $urgent = $self->urgent_package_id;

      cmd_error("You can't assign to urgent and some other package.")
        if $plan->{package}
        && grep {; $_ !=  $urgent } keys $plan->{package}->%*;

      $plan->{package}{ $self->urgent_package_id } = 1;
      next CMD;
    }

    if ($cmd eq 'start') {
      cmd_error("The /start command takes no arguments.") if @args;
      $plan->{start} = 1;
      next CMD;
    }

    if ($cmd eq 'estimate') {
      # This handling of args is silly. -- rjbs, 2019-06-21
      my ($low, $high) = split /\s*-\s*/, (join q{ }, @args), 2;
      $high //= $low;
      s/^\s+//, s/\s+$//, s/^\./0./, s/([0-9])$/$1h/ for $low, $high;
      my $low_s  = eval { parse_duration($low); };
      my $high_s = eval { parse_duration($high); };

      cmd_error(qq{I couldn't understand the /assign estimate "@args".})
        unless defined $low_s && defined $high_s;

      $plan->{estimate} = { low => $low_s / 3600, high => $high_s / 3600 };
      next CMD;
    }

    if ($cmd eq 'project') {
      cmd_error("You used /project without a project shortcut.")
        unless @args;

      cmd_error("You used /project with more than one argument.")
        if @args > 1;

      $plan->{project}{$args[0]} = 1;
      next CMD;
    }

    if ($cmd eq 'assign') {
      cmd_error("You used /assign without any usernames.") unless @args;
      push $plan->{usernames}->@*, @args;
      next CMD;
    }

    if ($cmd eq 'done') {
      cmd_error("The /done command takes no arguments.") if @args;
      $plan->{done} = 1;
      next CMD;
    };

    if ($cmd eq 'log') {
      my $dur = join q{ }, @args;

      s/^\s+//, s/\s+$//, s/^\./0./, s/([0-9])$/$1h/ for $dur;
      my $secs = eval { parse_duration($dur) };

      cmd_error(qq{I couldn't understand the /log duration "$dur".})
        unless defined $secs;

      if ($secs > 12 * 86_400) {
        my $dur_restr = duration($secs);
        cmd_error(
            qq{You said to spend "$dur" which I read as $dur_restr.  }
          . qq{That's too long!}
        );
      }

      $plan->{log_hours} = $secs / 3600;
      next CMD;
    }

    cmd_error("There's no /$cmd command.");
  }

  if (%error) {
    return (0, (join q{  }, sort keys %error));
  }

  return (1, undef);
}

sub _item_from_token ($self, $token) {
  # MAYBE TODO: Offer a means to only resolve shortcuts of a known type?
  # -- rjbs, 2019-05-24
  if ($token =~ s/\A(?:LP)?\*//i) {
    return $self->task_for_shortcut($token);
  }

  if ($token =~ s/\A(?:LP)?\#//i) {
    return $self->project_for_shortcut($token);
  }

  if ($token =~ /\A(?:LP)?([0-9]+)\z/i) {
    # We build these objects too much. :'(  -- rjbs, 2019-05-24
    my $id  = $1;
    my $lpc = $self->lp_client_for_master;
    my $task_res = $lpc->get_item($id);
    return ($task_res->payload, undef) if $task_res->is_success;
    return (undef, "No item found.");
  }

  BY_URL: {
    if (
      $token =~ m{\A\s*(?:https://app.liquidplanner.com/space/([0-9]+)/.*/)?([0-9]+)P?/?\s*\z}
    ) {
      my ($workspace_id, $task_id) = ($1, $2);
      last BY_URL unless $workspace_id == $self->workspace_id;

      my $lpc = $self->lp_client_for_master;
      my $task_res = $lpc->get_item($task_id);
      return ($task_res->payload, undef) if $task_res->is_success;
      return (undef, "No item found.");
    }
  }

  return (
    undef,
    qq{I couldn't figure out how to make "$token" into a LiquidPlanner item.},
  );
}

sub _handle_comment ($self, $event, $text) {
  $event->mark_handled;

  return $self->error_reply("Sorry, I didn't understand your comment command.")
    unless $text =~ s/\Aon\s+//;

  # We want to accept "update lp 123 ..." just like "update lp123", because
  # we are not monsters. -- rjbs, 2019-05-24
  $text =~ s/\A(LP)\s+/$1/gi;

  my ($what, $comment) = split /(?<!^https)[\s:]\s*/, $text, 2;

  my ($item, $error) = $self->_item_from_token($what);

  unless ($item) {
    return $event->error_reply($error);
  }

  my $lpc = $self->f_lp_client_for_user($event->from_user);

  my $post = $lpc->http_post("/treeitems/$item->{id}/comments",
    Content_Type => 'application/json',
    Content => $JSON->encode({
      comment => {
        comment => "$comment",
        item_id => $item->{id},
      },
    }),
  );

  my $uri   = $self->item_uri($item->{id});
  my $plain = "Commented on \l$item->{type}: $item->{name} ($uri)";
  my $slack = sprintf "Commented on \l$item->{type} %s.",
    $self->_slack_item_link_with_name($item);

  $post
    ->then(sub { return $event->reply($plain, { slack => $slack }); })
    ->else(sub {
      $event->reply_error("Something went wrong leaving that comment!")
    })
    ->retain;

  return;
}

sub _handle_update ($self, $event, $text) {
  $event->mark_handled;

  # We want to accept "update lp 123 ..." just like "update lp123", because
  # we are not monsters. -- rjbs, 2019-05-24
  $text =~ s/\A(LP)\s+/$1/gi;

  my ($what, $cmdstr) = split /\s+/, $text, 2;

  my ($item, $error) = $self->_item_from_token($what);

  unless ($item) {
    return $event->error_reply($error);
  }

  my $method_name = "_handle_update_for_\L$item->{type}";

  my $method = $self->can($method_name);

  unless ($method) {
    return $event->error_reply(
      "Sorry, I don't know how to update \L$item->{type}\Es."
    );
  }

  # parse commands for item type
  # report error if error
  # FOR NOW: dump plan
  # FOR LATER: dump plan if it contains undoable things; do otherwise
  # FOR LATEST: do everything
  return $self->$method_name($event, $item, $cmdstr);
}

sub _handle_update_for_task ($self, $event, $task, $cmd_line) {
  my $plan  = {};

  my ($ok, $error) = $self->_handle_subcmds('update', $cmd_line, $plan);

  return $event->error_reply($error) unless $ok;

  return $event->reply( "Update plan for LP$task->{id}: ```"
                      . JSON->new->canonical->encode($plan)
                      . "```");
}

sub _handle_update_for_project ($self, $event, $project, $cmd_line) {
  my ($first, $rest) = split /\s+/, $cmd_line, 2;

  return $event->error_reply(
    "Sorry, I don't know how to do much with projects."
  );
}

# One option:
# { text => "eat more pie (!) #project", usernames => [ @usernames ] }
# { text => "eat more pie␤/urgent /p project /assign bob /s␤longer form task" }
sub task_plan_from_spec ($self, $event, $spec) {
  my ($leader, $rest) = _split_lines($spec->{text}, 2);

  my (%plan, %error);

  ($leader, %plan) = $self->_extract_flags_from_task_text($leader);

  if ($spec->{usernames}) {
    $plan{usernames} //= [];
    push $plan{usernames}->@*, $spec->{usernames}->@*;
  }

  $plan{rest} = $rest;
  $plan{name} = $leader;
  $plan{user} = $event->from_user;

  $plan{name} =~ s/\b(ptn)([0-9]+)\b/$1 $2/gi;  # make ticket nums easier to copy

  $self->_check_plan_rest($event, \%plan, \%error);
  $self->_check_plan_usernames($event, \%plan, \%error) if $plan{usernames};
  $self->_check_plan_project($event, \%plan, \%error)   if $plan{project};
  $self->_check_plan_package($event, \%plan, \%error)   if $plan{package};

  $error{name} = "That task name is just too long!  Consider putting more of it in the long description.  You can do that by separating the name and long description with `---` (and spaces around that)."
    if length $plan{name} > 200;

  return (undef, \%error) if %error;
  return (\%plan, undef);
}

sub _handle_task ($self, $event, $text) {
  # because of "new task for...";
  my $what = $text =~ s/\Atask\s+//r;

  if ($text =~ /\A \s* shortcuts \s* \z/xi) {
    return $self->_handle_task_shortcuts($event, $text);
  }

  my ($target, $spec_text) = $what =~ /\s*for\s+@?(.+?)\s*:\s+((?s:.+))\z/;

  unless ($target and $spec_text) {
    return $event->error_reply("Does not compute.  Usage:  *task for `WHO`: `NAME`*");
  }

  my @target_names = split /(?:\s*,\s*|\s+and\s+)/, $target;

  my ($plan, $error) = $self->task_plan_from_spec(
    $event,
    {
      usernames => [ @target_names ],
      text      => $spec_text,
    },
  );

  $self->_execute_task_creation_plan($event, $plan, $error);
}

sub _execute_task_creation_plan ($self, $event, $plan, $error) {
  if ($error) {
    my $errors = join q{  }, values %$error;
    return $event->error_reply($errors);
  }

  my $user = $event->from_user;
  my $arg  = {};

  my $task_f = $self->_create_lp_task($event, $plan, $arg);

  $task_f->on_fail(sub {
    $event->reply(
      "Sorry, something went wrong when I tried to make that task.",
      $arg,
    );
  });

  $task_f->then(sub ($task) {
    my %todo;

    my $lpc = $self->f_lp_client_for_user($user);

    if ($plan->{start}) {
      $todo{timer} = $lpc->start_timer_for_task_id($task->{id})
        ->then(sub {
          $self->set_last_lp_timer_task_id_for_user($user, $task->{id});
          Future->done;
        });
    }

    if ($plan->{log_hours} || $plan->{done}) {
      $todo{track} = $lpc->track_time({
        task_id => $task->{id},
        work    => $plan->{log_hours} || 0,
        done    => $plan->{done},
        member_id   => $user->lp_id,
        activity_id => $task->{activity_id},
      })->then(sub {
        Future->done({
          work => $plan->{log_hours},
          done => $plan->{done},
        });
      });
    }

    # So, the callback is passed the same hashref that we pass to wait_named,
    # which is just \%todo, so why not close over %todo?  I think I am being
    # helpful to readability here, but maybe I'm being a jerk.  Only time will
    # tell.  -- rjbs, 2019-04-19
    $lpc->wait_named(\%todo)->then(sub {
      my $reply_base
        = "created, assigned to "
        . (join q{ and }, map {; $_->username } $plan->{owners}->@*);

      if ($todo{track}) {
        if ($todo{track}->is_done) {
          my $track = $todo{track}->get;
          $reply_base .=
            ($track->{log_hours}  ? sprintf(', logged %0.2fh', $track->{log_hrs}) : q{})
          . ($track->{done}       ? (($track->{log_hours} ? q{,} : q{})
                                    . ' and marked it done') : q{});

        } else {
          $reply_base .= ', but something went wrong with the time tracking';
        }
      }

      if ($todo{timer}) {
        $reply_base .= q{  } .
          ($todo{timer}->is_done
          ? "Timer started."
          : "Something went wrong with starting your timer.");
      }

      my $item_uri = $self->item_uri($task->{id});

      my $plain = join qq{\n},
        "LP$task->{id} $reply_base.",
        "\N{LINK SYMBOL} $item_uri",
        "\N{LOVE LETTER} " . $task->{item_email};

      my $slack = sprintf "%s %s (<mailto:%s|email>)",
        $self->_slack_item_link($task),
        $reply_base,
        $task->{item_email};

      $event->reply($plain, { slack => $slack });
    });
  })->retain;

  return;
}

sub _start_timer ($self, $user, $task) {
  my $res = $self->lp_client_for_user($user)
                 ->start_timer_for_task_id($task->{id});

  return unless $res->is_success;

  # What does this mean?  Copied and pasted. -- rjbs, 2018-06-16
  return unless $res->payload->{start};

  $self->set_last_lp_timer_task_id_for_user($user, $task->{id});
  return 1;
}

sub upcoming_tasks_for_user ($self, $user, $count) {
  my $lpc = $self->lp_client_for_user($user);

  my $res = $lpc->upcoming_task_groups_for_member_id($user->lp_id, $count);

  return unless $res->is_success;

  my @tasks = map   {; $_->{items}->@* }
              grep  {; $_->{group} ne 'INBOX' }
              $res->payload_list;

  return \@tasks;
}

sub _format_item_list ($self, $itemlist, $display) {
  my $reply = q{};
  my $slack = q{};

  unless ($itemlist->{items}->@*) {
    return($display->{zero_text} // "Nothing matched that search.");
  }

  for my $item ($itemlist->{items}->@*) {
    my $uri = $self->item_uri($item->{id});
    $reply .= "$item->{name} ($uri)\n";

    my $icon = $item->{type} eq 'Task'    ? ($self->_is_urgent($item) ? "🔥"
                                                                      : "🌀")
             : $item->{type} eq 'Package' ? "📦"
             : $item->{type} eq 'Project' ? "📁"
             : $item->{type} eq 'Folder'  ? "🗂"
             : $item->{type} eq 'Inbox'   ? "📫"
             :                              "❓";

    $slack .= "$icon "
           .  $self->_slack_item_link_with_name(
                $item,
                {
                  urgency => 0,
                  ($display->{show} ? $display->{show}->%* : ()),
                }
              )
           .  "\n";
  }

  if (defined $display->{header}) {
    my $header = $display->{header} && $itemlist->{page}  ? "$display->{header}, page "
               : $display->{header}                       ? $display->{header}
               : $itemlist->{page}                        ? "Page "
               : Carp::confess("unreachable code");

    $header .= $itemlist->{page} if $itemlist->{page};
    $header .= " of " . ($itemlist->{more} ? "$itemlist->{page}+n" : $itemlist->{page})
                if defined $itemlist->{more};

    $slack = "*$header*\n$slack";
    $reply = "$header\n$reply";
  }

  chomp $reply;
  chomp $slack;

  return ($reply, { slack => $slack });
}

sub _handle_tasks ($self, $event, $text) {
  my $user = $event->from_user;

  my $page = 1;
  if (length $text) {
    if ($text =~ /\A\s*([1-9][0-9]*)\s*\z/) {
      $page = $1;
    } else {
      $event->error_reply(qq{It's "tasks" and then optionally a page number.});
      return;
    }
  }

  if ($page > 10) {
    return $event->error_reply(
      "If it's not in your first ten pages, better go to the web.",
    );
  }

  # paginator
  #   tells you how many to query
  #   takes page number
  #   takes callback for filter,
  #   returns (set-of-items, has-more)

  my $per_page = 10;
  my $count = $per_page * $page;
  my $start = $per_page * ($page - 1);

  my %seen;
  my @lp_tasks  = grep {; ! $seen{$_->{id}}++ }
                  $self->upcoming_tasks_for_user($user, $count + 10)->@*;

  splice @lp_tasks, 0, $start;
  my @task_page = splice @lp_tasks, 0, $per_page;

  return $event->reply("You don't have any open tasks right now.  Woah!")
    unless @task_page;

  $Logger->log([ "WTF: <@lp_tasks> <@task_page>" ]);

  $event->reply(
    $self->_format_item_list(
      {
        items   => \@task_page,
        more    => (@lp_tasks > 0 ? 1 : 0),
        page    => $page,
      },
      {
        header  => sprintf("Upcoming tasks for %s", $user->username),
      },
    ),
  );
}

sub _parse_search ($self, $text) {
  my %aliases = (
    u => 'owner',
    o => 'owner',
    user => 'owner',
  );

  state $prefix_re  = qr{!?\^?};

  my $fallback = sub ($text_ref) {
    if ($$text_ref =~ s/^\#($Synergy::Util::ident_re)(?: \s | \z)//x) {
      return [ project => "#$1" ],
    }

    if ($$text_ref =~ s/^($prefix_re)$Synergy::Util::qstring\s*//x) {
      my ($prefix, $word) = ($1, $2);

      return [
        'name',
        ( $prefix eq ""   ? "contains"
        : $prefix eq "^"  ? "starts_with"
        : $prefix eq "!^" ? "does_not_start_with"
        : $prefix eq "!"  ? "does_not_contain" # fake operator
        :                   ()),
        ($word =~ s/\\(["“”])/$1/gr)
      ]
    }

    # Just a word.
    ((my $token), $$text_ref) = split /\s+/, $$text_ref, 2;
    $token =~ s/\A($prefix_re)//;
    my $prefix = $1;

    return [
      'name',
      ( $prefix eq ""    ? "contains"
      : $prefix eq "^"   ? "starts_with"
      : $prefix eq "!^"  ? "does_not_start_with"
      : $prefix eq "!"   ? "does_not_contain" # fake operator
      :                    undef),
      $token,
    ];
  };

  my $hunks = Synergy::Util::parse_colonstrings($text, { fallback => $fallback });

  canonicalize_names($hunks, \%aliases);

  # XXX This is garbage, we want a "real" error.
  # The valid forms are [ name => value ] and [ name => op => value ]
  # so [ name => x = y => z... ] is too many and we barf.
  # -- rjbs, 2019-06-23
  return undef if grep {; @$_ > 3 } @$hunks;

  return [
    map {;
      +{
        field => $_->[0],
        (@$_ > 2) ? (op => $_->[1], value => $_->[2])
                  : (               value => $_->[1]),
      }
    } @$hunks
  ];
}

sub _compile_search ($self, $conds, $from_user) {
  my %flag;
  my %display;
  my %error;

  my @unknown_fields;
  my @unknown_users;

  my sub cond_error ($str) {
    no warnings 'exiting';
    $error{$str} = 1;
    next COND;
  }

  my sub bad_value ($field) {
    cond_error("I don't understand the value you gave for `$field:`.");
  }

  my sub bad_op ($field, $op) {
    cond_error("I don't understand the operator you gave in `$field:$op`.");
  }

  my sub maybe_conflict ($field, $value) {
    cond_error("You gave conflicting values for `$field`.")
      if exists $flag{$field} && differ($flag{$field}, $value);
  }

  my sub differ ($x, $y) {
    return 1 if defined $x xor defined $y;
    return 1 if defined $x && $x ne $y;
    return 0;
  }

  my sub normalize_bool ($field, $value) {
    my $to_set  = $value eq 'yes'   ? 1
                : $value eq 1       ? 1
                : $value eq 'no'    ? 0
                : $value eq 0       ? 0
                : $value eq 'both'  ? undef
                : $value eq '*'     ? undef
                :                     -1;

    bad_value($field) if defined $to_set && $to_set == -1;
    return $to_set;
  }

  COND: for my $cond (@$conds) {
    # field and op are guaranteed to be in fold case.  Value, not.
    my $field = $cond->{field};
    my $op    = $cond->{op};
    my $value = $cond->{value};

    if (grep {; $field eq $_ } qw(done onhold scheduled)) {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = normalize_bool($field, fc $value);

      maybe_conflict($field, $value);

      $flag{$field} = $value;
      next COND;
    }

    if ($field eq 'in') {
      $field = 'project' if $value =~ /\A#/;
    }

    if ($field eq 'in') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;
      my $to_set = $value eq 'inbox'      ? $self->inbox_package_id
                 : $value eq 'urgent'     ? $self->urgent_package_id
                 : $value =~ /\A[0-9]+\z/ ? $value
                 : undef;

      bad_value($field) unless defined $to_set;

      # We could really allow multiple in: here, if we rejigger things.  But do
      # we care enough?  I don't, right this second. -- rjbs, 2019-03-30
      maybe_conflict('in', $to_set);

      $flag{in} = $to_set;
      next COND;
    }

    if ($field eq 'project') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;
      $value =~ s/\A#//;
      my ($item, $err) = $self->project_for_shortcut($value);

      cond_error($err) if $err;
      maybe_conflict('project', $item->{id});

      $flag{project} = $item->{id};
      next COND;
    }

    if ($field eq 'tags') {
      bad_op($field, $op) unless ($op//'include') eq 'include';

      $value = fc $value;

      $flag{tags}{$value} = 1;
      next COND;
    }

    if ($field eq 'client') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;
      bad_value('client') unless my $client = $self->client_named($value);

      maybe_conflict('client', $client->{id});

      $flag{client} = $client->{id};
      next COND;
    }

    if ($field eq 'shortcut') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      cond_error(q{The only valid values for `shortcut` are `*` and `~`, meaning "shortcut defined" and "no shortcut defined", respectively.})
        unless $value eq '~' or $value eq '*';

      $flag{shortcut} = $value;
      next COND;
    }

    if ($field eq 'page') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      maybe_conflict('page', $value);

      cond_error("You have to pick a positive integer page number.")
        unless $value =~ /\A[1-9][0-9]*\z/;

      cond_error("Sorry, you can't get a page past the tenth.") if $value > 10;

      $flag{page} = $value;
      next COND;
    }

    if (grep {; $field eq $_ } qw(owner creator)) {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      my $target = $self->resolve_name($value, $from_user);
      my $lp_id  = $target && $target->lp_id;

      unless ($lp_id) {
        push @unknown_users, $value;
        next COND;
      }

      $flag{$field}{$lp_id} = 1;
      next COND;
    }

    for my $pair (
      [ escalation   => [ qw(e esc escalation) ] ],
      [ stakeholders => [ qw(stake stakeholder stakeholders) ] ],
    ) {
      if (grep {; $field eq $_ } $pair->[1]->@*) {
        # These aren't a LiquidPlanner thing, we made them up, so they store
        # canonical usernames, not a member id.  We'll have some sanity check
        # that makes sure we don't have ones with garbage.  Also, we use
        # "contains" because they're comma lists.
        bad_op($field, $op) unless ($op//'is') eq 'is';

        if ($value eq '~') {
          $flag{$pair->[0]}{'~'} = 1;
          next COND;
        }

        my $target = $self->resolve_name($value, $from_user);

        unless ($target) {
          push @unknown_users, $value;
          next COND;
        }

        $flag{$pair->[0]}{$target->username} = 1;
        next COND;
      }
    }

    if ($field eq 'type') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;

      bad_value($field)
        unless $value =~ /\A (?: project | task | package | \* ) \z/x;

      maybe_conflict('type', $value);

      # * means explicit "no filter"
      $flag{$field} = $value eq '*' ? undef : $value;
      next COND;
    }

    if ($field eq 'phase') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      # TODO: get phases from LP definition
      my %Phase = (
        none      => 'none',
        flight    => 'In Flight',
        longhaul  => 'Long Haul',
        map {; $_ => ucfirst } qw(desired planning waiting circling landing)
      );

      my $to_set = $Phase{ fc $value };

      bad_value($field) unless $to_set;

      $flag{$field} = $to_set;
      next COND;
    }

    if ($field eq 'created' or $field eq 'lastupdated') {
      cond_error("The `$field` term has to be used like this: `$field:before:YYYY-MM-DD` (or use _after_ instead of _before_).")
        unless defined $op and ($op eq 'after' or $op eq 'before');

      bad_value("$field:$op") unless $value =~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

      cond_error("You gave conflicting values for `$field:$op`.")
        if exists $flag{$field}{$op} && differ($flag{$field}{$op}, $value);

      $flag{$field}{$op} = $value;
      next COND;
    }

    if ($field eq 'show') {
      # Silly hack:  "show:X" means "show:X:yes" so when there is no op, we
      # turn the value into the op and replace the value with "yes".  This is
      # an abuse of the field/op/value system, but so is "show" itself… almost
      # makes you wonder if I'm a bad person for putting the abuse into the
      # code just about 30 minutes after the feature itself.
      # -- rjbs, 2019-03-31
      unless (defined $op) {
        $op = fc $value;
        $value = 'yes';
      }

      bad_op($field, $op) unless exists $Showable_Attribute{ $op };

      $value = normalize_bool($field, fc $value);

      cond_error("You gave conflicting values for `$field:$op`.")
        if exists $flag{$field}{$op} && differ($flag{$field}{$op}, $value);

      $flag{$field}{$op} = $value;
      next COND;
    }

    if ($field eq 'debug' or $field eq 'force') {
      # Whatever, if you put debug:anythingtrue in there, we turn it on.
      # Live with it. -- rjbs, 2019-02-07
      $flag{$field} = 1;
      next COND;
    }

    if ($field eq 'name') {
      # We punt on pretty much any validation here.  So be it.
      # -- rjbs, 2019-03-30
      $flag{name} //= [];
      push $flag{name}->@*, [ $op, $value ];
      next COND;
    }

    push @unknown_fields, $field;
  }

  if (@unknown_fields) {
    my $text = "You used some parameters I don't understand: "
             . join q{, }, sort uniq @unknown_fields;

    $error{$text} = 1;
  }

  if (@unknown_users) {
    my $text = "I don't know who these users are: "
             . join q{, }, sort uniq @unknown_users;

    $error{$text} = 1;
  }

  if (my $show = delete $flag{show}) {
    $display{show} = $show;
  }

  return (\%flag, \%display, (%error ? \%error : undef));
}

sub _handle_search ($self, $event, $text) {
  return $self->_do_search($event, $text);
}

sub _handle_psearch ($self, $event, $text) {
  return $self->_do_search($event, $text, {
    prepend_instructions => [
      { field => 'type', op => 'is', value => 'project' }
    ],
  });
}

sub _handle_tsearch ($self, $event, $text) {
  return $self->_do_search($event, $text, {
    prepend_instructions => [
      { field => 'type', op => 'is', value => 'task' }
    ],
  });
}


sub _do_search ($self, $event, $text, $arg = {}) {
  my $instructions = $self->_parse_search($text);

  # This is stupid. -- rjbs, 2019-03-30
  unless (defined $instructions) {
    return $event->error_reply("Your search blew my mind, and now I am dead.");
  }

  unshift @$instructions, $arg->{prepend_instructions}->@*
    if $arg->{prepend_instructions};

  # This is very stupid. -- rjbs, 2019-06-06
  if (grep {; $_->{field} eq 'debug' and $_->{value} == 255 } @$instructions) {
    return $event->reply(
      "The search compiled as follows: ```"
      . JSON->new->pretty->canonical->encode($instructions)
      . "```"
    );
  }

  my ($search, $display, $error) = $self->_compile_search(
    $instructions,
    $event->from_user,
  );

  $display->{header} //= 'Search results';

  my $lpc = $self->f_lp_client_for_user($event->from_user);
  my $future = $self->_execute_search($lpc, $search, $error);
  $self->_send_search_result($event, $future, $display);
}

sub _send_search_result ($self, $event, $result, $display) {
  $result
    ->else(sub {
      $event->error_reply("Something went wrong with that search.");
      return Future->done;
    })
    ->then(sub ($action, @rest) {
      if    ($action eq 'reply')    { $event->reply(@rest) }
      elsif ($action eq 'error')    { $event->error_reply(@rest) }
      elsif ($action eq 'itemlist') {
        my ($itemlist) = @rest;
        $event->reply( $self->_format_item_list($itemlist, $display) );
      } else {
        $Logger->log([ "got unexpected search execution result: %s", [ $action, @rest ] ]);
        $event->error_reply("Woah, something weird happened with that search.");
      }
      return Future->done;
    })->retain;
}

sub _execute_search ($self, $lpc, $search, $orig_error = undef) {
  my %flag  = $search ? %$search : ();

  my %error = $orig_error ? %$orig_error : ();

  my %qflag = (flat => 1, depth => -1, order => 'earliest_start');
  my $q_in;
  my @filters;

  my $has_strong_check = 0;

  # We start with a limit higher than one page because there are reasons we
  # need to overshoot.  One common reason: if we've got an "in" filter, the
  # container may be removed, and we want to drop it.  We'll crank the limit up
  # more, later, if we're filtering by user on un-done tasks, because the
  # LiquidPlanner behavior on owner filtering is less than ideal.
  # -- rjbs, 2019-02-18
  my $page_size = 10;
  my ($limit, $offset) = ($page_size + 5, 0);

  $flag{done} = 0 unless exists $flag{done};
  if (defined $flag{done}) {
    push @filters, [ 'is_done', 'is', ($flag{done} ? 'true' : 'false') ];
  }

  if (defined $flag{onhold}) {
    push @filters, [ 'is_on_hold', 'is', ($flag{onhold} ? 'true' : 'false') ];
  }

  if (defined $flag{scheduled}) {
    push @filters, $flag{scheduled}
      ? [ 'earliest_start', 'after', '2001-01-01' ]
      : [ 'earliest_start', 'never' ];
  }

  if (defined $flag{project}) {
    push @filters, [ 'project_id', '=', $flag{project} ];
  }

  if (defined $flag{client}) {
    push @filters, [ 'client_id', '=', $flag{client} ];
  }

  if (defined $flag{tags}) {
    push @filters, [ 'tags', 'include', join q{,}, keys $flag{tags}->%* ];
  }

  {
    my %datefield = (created => 'created', lastupdated => 'last_updated');

    for my $field (keys %datefield) {
      if (my $got = $flag{$field}) {
        for my $op (qw( after before )) {
          if ($got->{$op}) {
            push @filters, [ $datefield{$field}, $op, $got->{$op} ];
          }
        }
      }
    }
  }

  $flag{page} //= 1;
  if ($flag{page}) {
    $offset = ($flag{page} - 1) * 10;
    $limit += $offset;
  }

  if ($flag{owner} && keys $flag{owner}->%*) {
    # So, this is really $!%@# annoying.  The owner_id filter finds tasks that
    # have an assignment for the given owner, but they don't care whether the
    # assignment is done or not.  So, if you're looking for tasks that are
    # undone for a given user, you need to do filtering in the application
    # layer, because LiquidPlanner does not have your back.
    # -- rjbs, 2019-02-18
    push @filters, map {; [ 'owner_id', '=', $_ ] } keys $flag{owner}->%*;

    if (defined $flag{done} && ! $flag{done}) {
      # So, if we're looking for specific users, and we want non-done tasks,
      # let's only find ones where those users' assignments are not done.
      # We'll have to do that filtering at this end, so we need to over-select.
      # I have no idea what to guess, so I picked 3x, just because.
      # -- rjbs, 2019-02-18
      $limit *= 3;
    }
  }

  if ($flag{creator} && keys $flag{creator}->%*) {
    push @filters, map {; [ 'created_by', '=', $_ ] } keys $flag{creator}->%*;
  }

  for my $field (qw( escalation stakeholders )) {
    if ($flag{$field} && keys $flag{$field}->%*) {
      push @filters, map {;
        [
          "custom_field:\u$field",
          ($_ eq '~' ? 'is_not_set' : ('contains', $_)),
        ]
      } keys $flag{$field}->%*;
    }
  }

  if (defined $flag{phase}) {
    # If you're asking for something by phase, you probably want a project.
    # You can override this if you want with "phase:planning type:task" but
    # it's a little weird. -- rjbs, 2019-02-07
    $flag{type} //= 'project';

    push @filters,
      $flag{phase} eq 'none'
      ? [ "custom_field:'Project Phase'", 'is_not_set' ]
      : [ "custom_field:'Project Phase'", '=', "'$flag{phase}'" ];
  }

  if ($flag{type}) {
    push @filters, [ 'item_type', 'is', ucfirst $flag{type} ];
  }

  if (defined $flag{in}) {
    $q_in = $flag{in};
  }

  if (defined $flag{done} and ! $flag{done}) {
    # If we're only looking at open tasks in one container, we'll assume it's a
    # small enough set to just search. -- rjbs, 2019-02-07
    $has_strong_check = 1 if $flag{in};

    # If we're looking for only open triage tasks, that should be small, too.
    # -- rjbs, 2019-02-08
    my $triage_user = $self->hub->user_directory->user_named('triage');
    if ($triage_user && grep {; $_ == $triage_user->lp_id } keys $flag{owner}->%*) {
      $has_strong_check = 1;
    }
  }

  if (exists $flag{shortcut}) {
    if (
      ! $flag{type}
      or ($flag{type} ne 'task' && $flag{type} ne 'project')
    ) {
      $error{"You can't search by missing shortcuts unless you specify a `type` of project or task."} = 1;
    } else {
      push @filters, [
        "custom_field:'Synergy \u$flag{type} Shortcut'",
        ( $flag{shortcut} eq '~' ? 'is_not_set'
        : $flag{shortcut} eq '*' ? 'is_set'
        :                           'designed_to_fail'), # no -r
      ];
    }
  }

  $has_strong_check = 1
    if ($flag{project} || $flag{in})
    || ($flag{debug} || $flag{force})
    || ($flag{type} && $flag{type} ne 'task')
    || ($flag{phase} && (defined $flag{done} && ! $flag{done})
                     && ($flag{phase} ne 'none' || $flag{type} ne 'task'));

  if ($flag{name}) {
    MATCHER: for my $matcher ($flag{name}->@*) {
      my ($op, $value) = @$matcher;
      if ($op eq 'does_not_contain') {
        state $error = qq{Annoyingly, there's no "does not contain" }
                     . qq{query in LiquidPlanner, so you can't use "!" }
                     . qq{as a prefix.};

        $error{$error} = 1;
        next MATCHER;
      }

      if (! defined $op) {
        $error{ q{Something weird happened with your search.} } = 1;
        next MATCHER;
      }

      # You need to have some kind of actual search.
      $has_strong_check++ unless $op eq 'does_not_start_with';

      push @filters, [ 'name', $op, $value ];
    }
  }

  unless ($has_strong_check) {
    state $error = "This search is too broad.  Try adding search terms or "
                 . "more limiting conditions.  I'm sorry this advice is so "
                 . "vague, but the existing rules are silly and subject to "
                 . "change at any time.";

    $error{$error} = 1;
  }

  if (%error) {
    return Future->done(error => join q{  }, sort keys %error);
  }

  my %to_query = (
    in      => $q_in,
    flags   => \%qflag,
    filters => \@filters,
  );

  if ($flag{debug}) {
    return Future->done(
      reply => "I'm going to run this query: ```"
             . JSON->new->pretty->canonical->encode(\%to_query)
             . "```"
    );
  }

  my $search_f = $lpc
    ->query_items(\%to_query)
    ->else(sub {
      Future->done(error => "Something went wrong when running that search.");
    });

  $search_f->then(sub ($data) {
    my %seen;
    my @tasks = grep {; ! $seen{$_->{id}}++ } @$data;

    if ($q_in) {
      # If you search for the contents of n, you will get n back also.
      @tasks = grep {; $_->{id} != $q_in } @tasks;
    }

    if ($flag{owner} && keys $flag{owner}->%*
        && defined $flag{done} && ! $flag{done}
    ) {
      @tasks = grep {;
        keys $flag{owner}->%*
        ==
        grep {; ! $_->{is_done} and $flag{owner}{ $_->{person_id} } }
          $_->{assignments}->@*;
      } @tasks;
    }

    unless (@tasks) {
      return Future->done(itemlist => {
        items => [],
        more  => 0,
        page  => $flag{page},
      });
    }

    my $more  = @tasks > $offset + 11;
    @tasks = splice @tasks, $offset, 10;

    return Future->done(reply => "That's past the last page of results.")
      unless @tasks;

    return Future->done(itemlist => {
      items => \@tasks,
      more  => $more ? 1 : 0,
      page  => $flag{page},
    });
  });
}

for my $package (qw(inbox urgent recurring)) {
  my $pkg_id_method = "$package\_package_id";
  Sub::Install::install_sub({
    as    => "_handle_$package",
    code  => sub ($self, $event, $text) {
      $self->_handle_quick_search(
        $event,
        $text,
        $package,
        sub ($, $, $search, $display) {
          $search->{owner}{ $event->from_user->lp_id } = 1;
          $search->{in} = $self->$pkg_id_method;

          # Later, we'll want to futz more when we can combine quick-searches
          # and search parameters. -- rjbs, 2019-06-27
          $display->{zero_text} = "Inbox hero!"
            if $package eq 'inbox';

          $display->{header} = sprintf '%s tasks for %s',
            ucfirst $package,
            $event->from_user->username;
          $display->{show}{urgency} = 0
            if $package eq 'urgent';
          $display->{show}{staleness} = 1
            if $package eq 'inbox'
            or $package eq 'urgent';
        },
      );
    },
  });
}

# add triage tag
sub _handle_triage ($self, $event, $text) {
  my $triage_user = $self->hub->user_directory->user_named('triage');

  return $event->error_reply("There is no triage user configured.")
    unless $triage_user;

  $self->_handle_quick_search(
    $event,
    $text,
    "triage",
    sub ($, $, $search, $display) {
      $search->{owner}{ $triage_user->lp_id } = 1;
      $display->{show}{age} = 1;
      $display->{show}{staleness} = 1;
      $display->{header} = "$TRIAGE_EMOJI Tasks to triage";
      $display->{zero_text} = "Triage zero!  Feelin' fine.";
    },
  )
}

sub _handle_quick_search ($self, $event, $text, $cmd, $munger) {
  if ($text && $text !~ /\A\s*([1-9][0-9]*)\s*\z/i) {
    return $event->error_reply(
      "The only argument for $cmd is an optional page number."
    );
  }

  my %display = ();
  my %search  = (page => $1 // 1);

  $self->$munger($event, \%search, \%display);

  my $lpc     = $self->f_lp_client_for_user($event->from_user);
  my $future  = $self->_execute_search($lpc, \%search, {});

  $self->_send_search_result($event, $future, \%display);
}

sub _handle_plus_plus ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->error_reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  unless (length $text) {
    return $event->reply("Thanks, but I'm only as awesome as my creators.");
  }

  my $who     = $event->from_user->username;
  my $pretend = "task for $who: $text";

  if ($text =~ /\A\s*that\s*\z/) {
    my $last  = $self->get_last_utterance($event->source_identifier);

    unless (length $last) {
      return $event->error_reply("I don't know what 'that' refers to.");
    }

    $pretend = "task for $who: $last";
  }

  return $self->_handle_task($event, $pretend);
}

sub _handle_angle_angle ($self, $event, $text) {
  my ($target, $rest) = split /\s+/, $text, 2;

  $target =~ s/:$//;

  my $pretend = "task for $target: $rest";

  return $self->_handle_task($event, $pretend);
}

my @BYE = (
  "See you later, alligator.",
  "After a while, crocodile.",
  "Time to scoot, little newt.",
  "See you soon, raccoon.",
  "Auf wiedertippen!",
  "Later.",
  "Peace.",
  "¡Adios!",
  "Au revoir.",
  "221 2.0.0 Bye",
  "+++ATH0",
  "Later, gator!",
  "Pip pip.",
  "Aloha.",
  "Farewell, %n.",
);

sub _handle_good ($self, $event, $text) {
  my $user = $event->from_user;

  my ($what) = $text =~ /^([a-z_]+)/i;
  my ($reply, $expand, $stop, $end_of_day);

  if    ($what eq 'morning')    { $reply  = "Good morning!";
                                  $expand = 'morning'; }

  elsif ($what eq 'day_au')     { $reply  = "How ya goin'?";
                                  $expand = 'morning'; }

  elsif ($what eq 'day_de')     { $reply  = "Doch, wenn du ihn siehst!";
                                  $expand = 'morning'; }

  elsif ($what eq 'day')        { $reply  = "Long days and pleasant nights!";
                                  $expand = 'morning'; }

  elsif ($what eq 'afternoon')  { $reply  = "You, too!";
                                  $expand = 'afternoon' }

  elsif ($what eq 'evening')    { $reply  = "I'll be here when you get back!";
                                  $stop   = 1; }

  elsif ($what eq 'night')      { $reply  = "Sleep tight!";
                                  $stop   = 1;
                                  $end_of_day = 1; }

  elsif ($what eq 'riddance')   { $reply  = "I'll outlive you all.";
                                  $stop   = 1;
                                  $end_of_day = 1; }

  elsif ($what eq 'bye')        { $reply  = pick_one(\@BYE);
                                  $stop   = 1;
                                  $end_of_day = 1; }

  if ($reply) {
    $reply =~ s/%n/$user->username/ge;
  }

  if ($reply and not $self->auth_header_for($user)) {
    $event->mark_handled;
    return $event->reply($reply);
  }

  if ($expand && $user->tasks_for_expando($expand)) {
    $self->expand_tasks($event, $expand, "$reply  ");
    $reply = '';
  }

  if ($stop) {
    my $timer_res = $self->lp_client_for_user($user)->my_running_timer;
    unless ($timer_res->is_success) {
      $event->mark_handled;
      return $event->reply("I couldn't figure out whether you had a running timer, so I gave up.")
    }

    if ($timer_res->has_payload) {
      $event->mark_handled;
      return $event->reply("You've got a running timer!  You should commit it.")
    }
  }

  if ($end_of_day && (my $sy_timer = $self->timer_for_user($user))) {
    my $time = parse_time_hunk('until tomorrow', $user);
    $sy_timer->chilltill($time);
    $self->save_state;
  }

  if ($reply) {
    $event->mark_handled;
    return $event->reply($reply);
  }
}

sub _handle_expand ($self, $event, $text) {
  my $user = $event->from_user;
  my ($what) = $text =~ /^([a-z_]+)/i;
  $self->expand_tasks($event, $what);
}

sub expand_tasks ($self, $event, $expand_target, $prefix='') {
  my $user = $event->from_user;

  my $lpc = $self->lp_client_for_user($user);

  unless ($expand_target && $expand_target =~ /\S/) {
    my @names = sort $user->defined_expandoes;
    return $event->reply($prefix . "You don't have any expandoes") unless @names;
    return $event->reply($prefix . "Your expandoes: " . (join q{, }, @names));
  }

  my @tasks = $user->tasks_for_expando($expand_target);
  return $event->error_reply($prefix . "You don't have an expando for <$expand_target>")
    unless @tasks;

  my $parent = $self->recurring_package_id;
  my $desc = $event->description;

  my (@ok, @fail);
  for my $task (@tasks) {
    my $payload = {
      task => {
        name        => $task,
        parent_id   => $parent,
        assignments => [ { person_id => $user->lp_id } ],
        description => $desc,
      }
    };

    $Logger->log([ "creating LP task: %s", $payload ]);

    my $res = $lpc->create_task($payload);

    if ($res->is_success) {
      push @ok, $task;
    } else {
      push @fail, $task;
    }
  }

  my $reply;
  if (@ok) {
    $reply = "I created your $expand_target tasks: " . join(q{; }, @ok);
    $reply .= "  Some tasks failed to create: " . join(q{; }, @fail) if @fail;
  } elsif (@fail) {
    $reply = "Your $expand_target tasks couldn't be created.  Sorry!";
  } else {
    $reply = "Something impossible happened.  How exciting!";
  }

  $event->reply($prefix . $reply);
  $event->mark_handled;
}

sub _create_lp_task ($self, $event, $my_arg, $arg) {
  my %container = (
    package_id  => $my_arg->{package_id}
                ?  $my_arg->{package_id}
                :  $self->inbox_package_id,
    parent_id   => $my_arg->{project_id}
                ?  $my_arg->{project_id}
                :  undef,
  );

  $container{parent_id} = delete $container{package_id}
    unless $container{parent_id};

  my sub assignment ($who) {
    return {
      person_id => $who->lp_id,
      ($my_arg->{estimate} ? (estimate => $my_arg->{estimate}) : ()),
    }
  }

  my $payload = {
    task => {
      name        => $my_arg->{name},
      assignments => [ map {; assignment($_) } @{ $my_arg->{owners} } ],
      description => $my_arg->{description},

      %container,
    }
  };

  my $as_user = $my_arg->{user} // $self->master_lp_user;
  my $lpc = $self->f_lp_client_for_user($as_user);

  my $chan_desc = $event->from_channel->describe_conversation($event);
  my $task_f = $lpc->create_task($payload);

  return $task_f->then(sub ($task) {
    # If the task is assigned to the triage user, inform them.
    # -- rjbs, 2019-02-28
    my $triage_user = $self->hub->user_directory->user_named('triage');
    if ($triage_user && $triage_user->has_lp_id) {
      if (grep {; $_->{person_id} eq $triage_user->lp_id } @{ $task->{assignments} }) {
        my $who = $my_arg->{user} ? $my_arg->{user}->username : "some weirdo";

        my $text = sprintf
          "$TRIAGE_EMOJI New task created for triage by %s in %s: %s (%s)",
          $who,
          $chan_desc,
          $task->{name},
          $self->item_uri($task->{id});

        my $alt = {
          slack => sprintf "$TRIAGE_EMOJI *New task created for triage by %s in %s*: %s",
            $who,
            $chan_desc,
            $self->_slack_item_link_with_name($task)
        };

        $self->_inform_triage($text, $alt);
      }
    }

    return Future->done($task);
  });
}

sub _inform_triage ($self, $text, $alt = {}) {
  return unless $self->triage_channel_name;
  return unless my $channel = $self->hub->channel_named($self->triage_channel_name);

  if (my $rototron = $self->_rototron) {
    my $roto_reactor = $self->hub->reactor_named('rototron');

    for my $officer ($roto_reactor->current_triage_officers) {
      $channel->send_message_to_user($officer, $text, $alt);
    }
  }

  if ($self->triage_channel_name && $self->triage_address) {
    $channel->send_message($self->triage_address, $text, $alt);
  }
}

sub lp_timer_for_user ($self, $user) {
  return unless $self->auth_header_for($user);

  my $timer_res = $self->lp_client_for_user($user)->my_running_timer;

  return unless $timer_res->is_success;

  my $timer = $timer_res->payload;

  if ($timer) {
    $self->set_last_lp_timer_task_id_for_user($user, $timer->item_id);
  }

  return $timer;
}

sub _handle_showtime ($self, $event, $text) {
  my $user  = $event->from_user;
  my $timer = $user
            ? $self->timer_for_user($user)
            : undef;

  return $event->reply($ERR_NO_LP)
    unless $timer;

  if ($timer->has_chilltill and $timer->chilltill > time) {
    if ($timer->is_business_hours) {
      $event->reply("Okay, back to work!");
    } else {
      $event->reply("Back to normal business hours, then.");
    }
  } elsif ($timer->is_business_hours) {
    $event->reply("I thought it was already showtime!");
  } else {
    $timer->start_showtime;
    return $event->reply("Okay, business hours extended!");
  }

  $timer->clear_chilltill;
  $self->save_state;
  return;
}

sub _handle_shows ($self, $event, $text) {
  return $self->_handle_chill($event, 'until tomorrow')
    if $text =~ /\s*over\s*[+!.]*\s*\z/i;

  $event->mark_unhandled;

  return;
}

sub _handle_chill ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->error_reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  {
    my $timer_res = $self->lp_client_for_user($user)->my_running_timer;

    return $event->reply("You've got a running timer!  You should commit it.")
      if $timer_res->is_success && $timer_res->has_payload;
  }

  my $sy_timer = $self->timer_for_user($user);

  $text =~ s/[.!?]+\z// if length $text;

  if (! length $text or $text =~ /^until\s+I'm\s+back\s*$/i) {
    $sy_timer->chill_until_active(1);
    $self->save_state;
    return $event->reply("Okay, I'll stop pestering you until you've active again.");
  }

  my $time = parse_time_hunk($text, $user);
  return $event->error_reply("Sorry, I couldn't parse '$text' into a time")
    unless $time;

  my $when = DateTime->from_epoch(
    time_zone => $user->time_zone,
    epoch     => $time,
  )->format_cldr("yyyy-MM-dd HH:mm zzz");

  if ($time <= time) {
    $event->error_reply("That sounded like you want to chill until the past ($when).");
    return;
  }

  $sy_timer->chilltill($time);
  $self->save_state;
  $event->reply("Okay, no more nagging until $when");
}

sub _handle_triple_zed ($self, $event, $text) {
  $self->_handle_chill($event, "");
}

my %TIMER_COMMAND = map {; $_ => $_ } qw(
  abort commit done reset resume start stop
);

$TIMER_COMMAND{restart} = 'resume';

sub _handle_timer ($self, $event, $text) {
  my $user = $event->from_user;

  if (length $text) {
    $text =~ s/^\s*//;
    $text =~ s/\s*$//;
    my ($next, $rest) = split /\s+/, $text, 2;

    return $event->error_reply("Sorry, I don't understand your timer command.")
      unless my $name = $TIMER_COMMAND{$next};

    # ...because later we will error unless: ($rest//'timer') eq 'timer'
    undef $rest unless length $rest;

    my $method = "_handle_timer_$name";

    return $self->$method($event, $rest);
  }

  return $event->error_reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  my $timer = $timer_res->payload;
  my $sy_timer = $self->timer_for_user($user);

  unless ($timer) {
    my $nag = $sy_timer->last_relevant_nag;
    my $msg;
    if (! $nag) {
      $msg = "You don't have a running timer.";
    } elsif ($nag->{level} == 0) {
      $msg = "Like I said, you don't have a running timer.";
    } else {
      $msg = "Like I keep telling you, you don't have a running timer!";
    }

    return $event->reply($msg);
  }

  my $time = $timer->real_total_time_duration;

  my $task_res = $lpc->get_item($timer->item_id);

  my $task = ($task_res->is_success && $task_res->payload)
          || { id => $timer->item_id, name => '??' };

  my $url = $self->item_uri($task->{id});

  my $base  = "Your timer has been running for $time, work on";
  my $slack = sprintf '%s: %s',
    $base, $self->_slack_item_link_with_name($task);

  return $event->reply(
    "$base: $task->{name} ($url)",
    {
      slack => $slack,
    },
  );
}

sub _handle_timer_abort ($self, $event, $text) {
  return $event->error_reply("I didn't understand your abort request.")
    unless ($text // 'timer') eq 'timer';

  my $user = $event->from_user;
  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $event->reply("You don't have a running timer to abort.")
    unless my $timer = $timer_res->payload;

  my $stop_res = $lpc->stop_timer_for_task_id($timer->item_id);
  my $clr_res  = $lpc->clear_timer_for_task_id($timer->item_id);

  my $task_was = '';

  my $task_res = $lpc->get_item($timer->item_id);

  if ($task_res->is_success) {
    my $uri = $self->item_uri($timer->item_id);
    $task_was = " The task was: " . $task_res->payload->{name} . " ($uri)";
  }

  if ($stop_res->is_success and $clr_res->is_success) {
    $self->timer_for_user($user)->clear_last_nag;
    $event->reply("Okay, I stopped and cleared your timer.$task_was");
  } else {
    $event->reply("Something went wrong aborting your timer.");
  }
}

sub _handle_timer_commit ($self, $event, $comment) {
  # commit                  | just commit the timer
  #
  # *** We'll call these "all caps" trailing words "meta" words.
  # commit DONE             | commit the timer, mark done
  # commit STOP             | commit the timer, stop it
  # commit STOP DONE        | commit the timer, stop it, mark it done
  # commit CHILL            | commit the timer, stop it, chill until active
  #
  # commit $comment         | commit the timer, leave a comment
  # commit $comment META... | commit the timer, leave a comment, do meta action
  #
  # commit that             | treat the last thing user said as the argument(s)
  my $user = $event->from_user;
  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  if ($event->text =~ /\A\s*that\s*\z/) {
    my $last  = $self->get_last_utterance($event->source_identifier);

    unless (length $last) {
      return $event->error_reply("I don't know what 'that' refers to.");
    }

    $comment = $last;
  }

  my $timer_override;
  my $time_re = qr{TIME ([0-9]+(?:\.[0-9]+))([hm]?)};

  my %meta;
  while ($comment =~ s/(?:\A|\s+)(DONE|STOP|SOTP|CHILL|$time_re)\s*\z//) {
    my $got = $1;
    if ($got =~ $time_re) {
      $timer_override = $1 * (($2 || 'h') eq 'h' ? 1 : 60);
    } else {
      $meta{$got}++;
    }
  }

  $meta{DONE} = 1 if $comment =~ /\Adone\z/i;
  $meta{STOP} = 1 if $meta{DONE} or $meta{CHILL} or $meta{SOTP};

  my $lp_timer = $self->lp_timer_for_user($user);

  return $event->reply("You don't seem to have a running timer.")
    unless $lp_timer && ref $lp_timer; # XXX <-- stupid return type

  my $sy_timer = $self->timer_for_user($user);
  return $event->reply("You don't timer-capable.") unless $sy_timer;

  my $task_id = $lp_timer->item_id;

  my $item_res = $lpc->get_item($task_id);
  unless ($item_res->is_success) {
    return $event->error_reply("I couldn't find the item you're talking about.");
  }

  my $item = $item_res->payload;

  my $activity_res = $lpc->get_activity_id($task_id, $user->lp_id);

  unless ($activity_res->is_success) {
    return $event->reply("I couldn't log the work because the task doesn't have a defined activity.");
  }

  my $activity_id = $activity_res->payload;

  if ($meta{STOP} and ! $sy_timer->chilling) {
    if ($meta{CHILL}) {
      $sy_timer->chill_until_active(1);
    } else {
      # Don't complain 30s after we stop work!  Give us a couple minutes to
      # move on to the next task. -- rjbs, 2015-04-21
      $sy_timer->chilltill(time + 300);
    }
  }

  my $task_base = "/tasks/$task_id";

  my $work_to_commit = $timer_override // $lp_timer->real_total_time;
  my $work_duration  = concise( duration( $work_to_commit * 3600 ) );

  my $cancel_done;
  if ($meta{DONE} && $item->{custom_field_values}{"Synergy Task Shortcut"}) {
    $meta{DONE} = 0;
    $cancel_done = 1;
  }

  my $commit_res = $lpc->track_time({
    task_id => $task_id,
    work    => $work_to_commit,
    done    => $meta{DONE},
    comment => $comment,
    member_id   => $user->lp_id,
    activity_id => $activity_id,
  });

  unless ($commit_res->is_success) {
    $self->save_state;
    return $event->reply("I couldn't commit your work, sorry.");
  }

  $sy_timer->clear_last_nag;
  $self->save_state;

  {
    my $clear_res = $lpc->clear_timer_for_task_id($task_id);
    $meta{CLEARFAIL} = ! $clear_res->is_success;
  }

  unless ($meta{STOP}) {
    my $start_res = $lpc->start_timer_for_task_id($task_id);
    $meta{STARTFAIL} = ! $start_res->is_success;
  }

  my $also
    = $meta{DONE}  ? " and marked your work done"
    : $meta{CHILL} ? " stopped the timer, and will chill until you're back"
    : $meta{STOP}  ? " and stopped the timer"
    :                "";

  my @errors = (
    ($meta{CLEARFAIL} ? ("I couldn't clear the timer's old value")  : ()),
    ($meta{STARTFAIL} ? ("I couldn't restart the timer")            : ()),
    ($cancel_done     ? ("I left it undone, because it has a shortcut") : ()),
  );

  if (@errors) {
    $also .= ".  I had trouble, though:  "
          .  join q{ and }, @errors;
  }

  my $uri = $self->item_uri($lp_timer->item_id);

  my $task_res = $lpc->get_item($task_id);
  unless ($task_res->is_success) {
    return $event->reply(
      "I logged that time, but something went wrong trying to describe it!"
      . (@errors ? ("  I had other trouble, too: " . join q{; }, @errors)
                 : q{}),
    );
  }

  my $task = $task_res->payload;

  my $base  = "Okay, I've committed $work_duration of work$also.  The task was:";
  my $text  = "$base $task->{name} ($uri)";
  my $slack = sprintf '%s  %s',
    $base, $self->_slack_item_link_with_name($task);

  $event->reply(
    $text,
    {
      slack => $slack,
    }
  );
}

sub _handle_timer_done ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $next;
  my $chill;
  if ($text) {
    my @things = split /\s*,\s*/, $text;
    for (@things) {
      if ($_ eq 'next')  { $next  = 1; next }
      if ($_ eq 'chill') { $chill = 1; next }

      return -1;
    }

    return $event->error_reply("No, it's nonsense to chill /and/ start a new task!")
      if $chill && $next;
  }

  $self->_handle_timer_commit($event, 'DONE');
  $self->_handle_timer_start($event, 'next') if $next;
  $self->_handle_chill($event, "until I'm back") if $chill;
  return;
}

sub _handle_timer_reset ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  return $event->error_reply("I didn't understand your timer reset request.")
    unless ($text // 'timer') eq 'timer';

  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $event->reply("You don't have a running timer to reset.")
    unless my $timer = $timer_res->payload;

  my $task_id = $timer->item_id;
  my $clr_res = $lpc->clear_timer_for_task_id($task_id);

  return $event->reply("Something went wrong resetting your timer.")
    unless $clr_res->is_success;

  $self->timer_for_user($user)->clear_last_nag;

  my $start_res = $lpc->stop_timer_for_task_id($task_id);

  if ($start_res->is_success) {
    $self->set_last_lp_timer_task_id_for_user($user, $task_id);
    $event->reply("Okay, I cleared your timer and left it running.");
  } else {
    $event->reply("Okay, I cleared your timer but couldn't restart it… sorry!");
  }
}

sub _handle_timer_resume ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->error_reply("I didn't understand your timer resume request.")
    unless ($text // 'timer') eq 'timer';

  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  my $lp_timer = $self->lp_timer_for_user($user);

  if ($lp_timer && ref $lp_timer) {
    my $task_res = $lpc->get_item($lp_timer->item_id);

    unless ($task_res->is_success) {
      return $event->reply("You already have a running timer (but I couldn't figure out its task…)");
    }

    my $task = $task_res->payload;
    return $event->reply("You already have a running timer ($task->{name})");
  }

  my $task_id = $self->last_lp_timer_task_id_for_user($user);

  unless ($task_id) {
    return $event->reply("I'm not aware of any previous timer you had running. Sorry!");
  }

  my $task_res = $lpc->get_item($task_id);

  unless ($task_res->is_success) {
    return $event->reply("I found your timer but I couldn't figure out its task…");
  }

  my $task = $task_res->payload;
  my $res  = $lpc->start_timer_for_task_id($task->{id});

  unless ($res->is_success) {
    return $event->reply("I failed to resume the timer for $task->{name}, sorry!");
  }

  return $event->reply(
    "Timer resumed. Task is: $task->{name}",
    {
      slack => sprintf("Timer resumed on %s",
        $self->_slack_item_link_with_name($task)),
    },
  );
}

sub _handle_timer_start ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  if ($text =~ m{\A\s*\*(\w+)\s*\z}) {
    my ($task, $error) = $self->task_for_shortcut($1);
    return $event->error_reply($error) unless $task;

    return $event->error_reply("You can only start timers on tasks, but that item is a \l$task->{type}.")
      unless $task->{type} eq 'Task';

    return $self->_handle_timer_start_existing($event, $task);
  }

  if ($text =~ /\A[0-9]+\z/) {
    my $task_id = $text;
    my $task_res = $lpc->get_item($task_id);

    return $event->reply("Sorry, something went wrong trying to find that task.")
      unless $task_res->is_success;

    return $event->error_reply("Sorry, I couldn't find that task.")
      if $task_res->is_nil;

    my $item = $task_res->payload;
    return $event->error_reply("You can only start timers on tasks, but that item is a \l$item->{type}.")
      unless $item->{type} eq 'Task';

    return $self->_handle_timer_start_existing($event, $item);
  }

  if ($text eq 'next') {
    my $lp_tasks = $self->upcoming_tasks_for_user($user, 1);

    unless ($lp_tasks && $lp_tasks->[0]) {
      return $event->reply("I can't get your tasks to start the next one.");
    }

    my $task = $lp_tasks->[0];
    my $start_res = $lpc->start_timer_for_task_id($task->{id});

    if ($start_res->is_success) {
      $self->set_last_lp_timer_task_id_for_user($user, $task->{id});

      my $uri   = $self->item_uri($task->{id});
      my $text  = "Started task: $task->{name} ($uri)";
      my $slack = sprintf "Started task %s.",
        $self->_slack_item_link_with_name($task);

      return $event->reply(
        $text,
        { slack => $slack },
      );
    } else {
      return $event->reply("I couldn't start your next task.");
    }
  }

  return $event->error_reply(q{You can either say "timer start TASK" or "timer start next".});
}

sub _handle_timer_start_existing ($self, $event, $task) {
  # TODO: make sure the task isn't closed! -- rjbs, 2016-01-25
  # TODO: print the description of the task instead of its number -- rjbs,
  # 2016-01-25
  my $user = $event->from_user;
  my $lpc  = $self->lp_client_for_user($user);
  my $start_res = $lpc->start_timer_for_task_id($task->{id});

  if ($start_res->is_success) {
    $self->set_last_lp_timer_task_id_for_user($user, $task->{id});

    my $uri   = $self->item_uri($task->{id});
    my $text  = "Started task: $task->{name} ($uri)";
    my $slack = sprintf "Started task %s",
      $self->_slack_item_link_with_name($task);

    return $event->reply(
      $text,
      { slack => $slack },
    );
  } else {
    return $event->reply("Sorry, something went wrong and I couldn't start the timer.");
  }
}

sub _handle_timer_stop ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->error_reply($ERR_NO_LP) unless $self->auth_header_for($user);

  return $event->reply("Quit it!  I'm telling mom!")
    if $text =~ /\Ahitting yourself[.!]*\z/;

  return $event->error_reply("I didn't understand your timer stop request.")
    unless ($text // 'timer') eq 'timer';

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $event->reply("You don't have a running timer to stop.")
    unless my $timer = $timer_res->payload;

  my $stop_res = $lpc->stop_timer_for_task_id($timer->item_id);
  return $event->reply("I couldn't stop your timer.")
    unless $stop_res->is_success;

  my $task_was = '';

  my $task_res = $lpc->get_item($timer->item_id);

  if ($task_res->is_success) {
    my $uri = $self->item_uri($timer->item_id);
    $task_was = " The task was: " . $task_res->payload->{name} . " ($uri)";

  }

  $self->timer_for_user($user)->clear_last_nag;
  return $event->reply("Okay, I stopped your timer.$task_was");
}

sub _handle_spent ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->error_reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  my ($dur_str, $name) = $text =~ /\A(\V+?)(?:\s*:|\s*\son)\s+(\S.+)\z/s;
  unless ($dur_str && $name) {
    return $event->error_reply("Does not compute.  Usage:  spent DURATION on DESC-or-ID-or-URL");
  }

  my $duration;
  my $ok = eval { $duration = parse_duration($dur_str); 1 };
  unless ($ok) {
    return $event->error_reply("I didn't understand how long you spent!");
  }

  if ($duration > 12 * 86_400) {
    my $dur_restr = duration($duration);
    return $event->error_reply(
        qq{You said to spend "$dur_str" which I read as $dur_restr.  }
      . qq{That's too long!},
    );
  }

  my $workspace_id = $self->workspace_id;

  if (
    $name =~ m{\A\s*(?:https://app.liquidplanner.com/space/$workspace_id/.*/)?([0-9]+)P?/?\s*\z}
  ) {
    my ($task_id) = ($1);
    return $self->_spent_on_existing($event, $task_id, $duration);
  }

  if ($name =~ m{\A\s*\*(\w+)(?:\s+(.+))?\z}) {
    my ($shortcut, $rest) = ($1, $2);

    my ($task, $error) = $self->task_for_shortcut($shortcut);
    return $event->reply($error) unless $task;

    my ($remainder, %plan) = $self->_extract_flags_from_task_text($rest);
    return $event->error_reply("I didn't understand all the flags you used.")
      if $remainder =~ /\S/;

    my $start = delete $plan{start};

    return $event->error_reply("The only special thing you can do when spending time on an existing task is start its timer.")
      if keys %plan;

    return $self->_spent_on_existing($event, $task->{id}, $duration, $start);
  }

  my ($plan, $error) = $self->task_plan_from_spec(
    $event,
    {
      usernames => [ $event->from_user->username ],
      text      => $name,
    },
  );

  # In other words, if the timer isn't going to be running, close the task.  If
  # you want to create a task with time already on it without closing it or
  # starting the timer, you can use normal task creation with /commands.
  $plan->{done} = 1 unless $plan->{start};

  $plan->{log_hours} = $duration / 3600;

  $self->_execute_task_creation_plan($event, $plan, $error);
}

sub _spent_on_existing ($self, $event, $task_id, $duration, $start = 0) {
  my $user = $event->from_user;

  my $lpc = $self->lp_client_for_user($user);

  my $activity_res = $lpc->get_activity_id($task_id, $user->lp_id);

  unless ($activity_res->is_success) {
    return $event->reply("I couldn't log the work because the task doesn't have a defined activity.");
  }

  my $activity_id = $activity_res->payload;

  my $track_ok = $lpc->track_time({
    task_id => $task_id,
    work    => $duration / 3600,
    member_id   => $user->lp_id,
    activity_id => $activity_id,
  });

  unless ($track_ok) {
    return $event->reply("I couldn't log your time, sorry.");
  }

  my $task_res = $lpc->get_item($task_id);

  unless ($task_res->is_success) {
    return $event->reply(
      "I logged that time, but something went wrong trying to describe it!"
    );
  }

  my $uri  = $self->item_uri($task_id);
  my $task = $task_res->payload;

  my $plain_base = qq{I logged that time on "$task->{name}"};
  my $slack_base = qq{I logged that time};

  if ($start) {
    if ($lpc->start_timer_for_task_id($task->{id})->is_success) {
      $plain_base .= " and started your timer";
      $slack_base .= " and started your timer";
    } else {
      $plain_base .= ", but I couldn't start your timer";
      $slack_base .= ", but I couldn't start your timer";
    }
  }

  $slack_base .= sprintf qq{.  The task is: %s},
    $self->_slack_item_link_with_name($task);

  return $event->reply(
    "$plain_base.\n$uri",
    {
      slack => $slack_base,
    }
  );
}

sub _handle_projects ($self, $event, $text) {
  my @sorted = sort $self->project_shortcuts;

  $event->reply("Responses to <projects> are sent privately.")
    if $event->is_public;

  my $reply = "Known projects:\n";
  my $slack = "Known projects:\n";

  for my $project (@sorted) {
    my ($item, $error) = $self->project_for_shortcut($project);
    next unless $item; # !?!? -- rjbs, 2018-06-30

    $reply .= sprintf "\n%s (%s)", $project, $self->item_uri($item->{id});
    $slack .= sprintf "\n%s", $self->_slack_item_link_with_name($item);
  }

  $event->private_reply($reply, { slack => $slack });
}

sub _handle_task_shortcuts ($self, $event, $text) {
  my @sorted = sort $self->task_shortcuts;

  $event->reply("Responses to <task shortcuts> are sent privately.")
    if $event->is_public;

  my $reply = "Known task shortcuts\n";
  my $slack = "Known task shortcuts\n";

  for my $task (@sorted) {
    my ($item, $error) = $self->task_for_shortcut($task);
    next unless $item; # !?!? -- rjbs, 2018-06-30

    $reply .= sprintf "\n%s (%s)", $task, $self->item_uri($item->{id});
    $slack .= sprintf "\n%s", $self->_slack_item_link_with_name($item);
  }

  $event->private_reply($reply, { slack => $slack });
}

sub _handle_todo ($self, $event, $text) {
  my $user = $event->from_user;
  my $desc = $text;

  # If it's for somebody else, it should be a task instead
  if ($desc =~ /^for\s+\S+?:/) {
    return $event->error_reply("Sorry, I can only make todo items for you");
  }

  my $lpc = $self->lp_client_for_user($user);

  my $todo_res = $lpc->create_todo_item({ title => $desc });

  my $reply = $todo_res->is_success
            ? qq{I added "$desc" to your todo list.}
            : "Sorry, I couldn't add that todo… for… some reason.";

  return $event->reply($reply);
}

sub _handle_todos ($self, $event, $text) {
  my $user = $event->from_user;
  my $lpc  = $self->lp_client_for_user($user);
  my $todo_res = $lpc->todo_items;
  return unless $todo_res->is_success;

  my @todos = grep {; ! $_->{is_done} } $todo_res->payload_list;

  return $event->reply("You don't have any open to-do items.") unless @todos;

  $event->reply("Responses to <todos> are sent privately.") if $event->is_public;
  $event->private_reply('Open to-do items:');

  for my $todo (@todos) {
    $event->private_reply("- $todo->{title}");
  }
}

sub _lp_assignment_is_unestimated {
  my ($self, $assignment) = @_;

  return ($assignment->{low_effort_remaining}  // 0) < 0.00000001
      && ($assignment->{high_effort_remaining} // 0) < 0.00000001;
}

sub _rototron ($self) {
  # TODO: indirection through rototron_reactor name on object
  return unless my $roto_reactor = $self->hub->reactor_named('rototron');
  return $roto_reactor->rototron;
}

sub _handle_iteration ($self, $event, $rest) {
  my $lpc = $self->lp_client_for_master;
  my $iteration
    = ! length $rest            ? $lpc->current_iteration
    : $rest =~ /^([-+][0-9]+)$/ ? $lpc->iteration_relative_to_current("$1")
    : $rest =~ /^([0-9]+)$/     ? $lpc->iteration_by_number("$1")
    : undef;

  $event->mark_handled;

  return $event->error_reply("Sorry, I couldn't find that iteration")
    unless $iteration;

  my $reply = sprintf "Iteration %s: %s to %s",
      $iteration->{number},
      $iteration->{start},
      $iteration->{end};

  return $event->reply(
    $reply . $self->item_uri($iteration->{package}),
    {
      slack => "$reply\n" .
               $self->_slack_item_link_with_name($iteration->{package}),
    }
  );
}

sub search_report ($self, $who, $arg = {}) {
  my $lpc = $self->f_lp_client_for_user($who);

  # We copy it so we can edit things.  It's stupid, but it works.
  # -- rjbs, 2019-06-08
  my @search = map {;
    my $new = { %$_ };
    $new->{value} = $who->lp_id if $new->{value} && $new->{value} eq '$TARGET';
    $new;
  } $arg->{search}->@*;

  my ($search, $display, $error) = $self->_compile_search(\@search, $who);

  if ($error && %$error) {
    # This is jank. -- rjbs, 2019-06-08
    $Logger->log([ "search report failed: %s", $error ]);
    return Future->done([ "[ search report failed! ]" ]);
  }

  my $future = $self->_execute_search($lpc, $search, {});
  $future->then(sub ($action, $itemlist) {
    unless ($action eq 'itemlist') {
      return Future->done([
        "Something weird happened building the search report."
      ]);
    }

    return Future->done unless $itemlist->{items}->@*;

    return Future->done([
      $self->_format_item_list($itemlist, $display)
    ]);
  });
}

sub container_report ($self, $who, $arg = {}) {
  return unless my $lp_id = $who->lp_id;

  my $rototron = $self->_rototron;
  my $user_is_triage = $who->is_on_triage;

  my $triage_user = $rototron
                  ? $self->hub->user_directory->user_named('triage')
                  : undef;

  my @to_check = (
    (! $arg->{exclude}{urgent}
      ? [ urgent => "🔥" => $self->urgent_package_id  ]
      : ()),

    (($user_is_triage && $triage_user && $triage_user->has_lp_id)
      ? [ triage => "⛑" => undef,  $triage_user->lp_id ]
      : ()),

    [ inbox  => "📫" => $self->inbox_package_id   ],

    (! $arg->{exclude}{scheduled}
      ? [ scheduled => "📉" => undef, undef,
          [ [ 'earliest_start', 'after', '2001-01-01' ],
            [ 'parent_id',  '!=', $self->urgent_package_id ],
            [ 'package_id', '!=', $self->urgent_package_id ],
          ] ]
      : ()),
  );

  my @summaries;

  my $lpc = $self->lp_client_for_user($who);

  CHK: for my $check (@to_check) {
    my ($label, $icon, $package_id, $want_lp_id, $more_filters) = @$check;
    $want_lp_id //= $lp_id;

    my $check_res = $lpc->query_items({
      ($package_id ? (in => $package_id) : ()),
      flags => {
        depth => -1,
        flat  => 1,
      },
      filters => [
        [ is_done   => 'is',  'false' ],
        [ owner_id  => '=',   $want_lp_id  ],
        ($more_filters ? @$more_filters : ()),
      ],
    });

    unless ($check_res->is_success) {
      push @summaries, "❌ Couldn't produce a report on $label tasks.";
      next CHK;
    }

    my $unest = 0;
    my $total = 0;

    my @ages;

    my $now = time;

    my %seen;
    for my $item ($check_res->payload_list) {
      next if $seen{$item->{id}}++; # Stupid duplicates! -- rjbs, 2019-06-08
      next unless $item->{type} eq 'Task'; # Whatever. -- rjbs, 2018-06-15
      my ($assign) = grep {; $_->{person_id} == $want_lp_id }
                     $item->{assignments}->@*;

      next unless $assign and ! $assign->{is_done};

      $total++;
      $unest++ if $self->_lp_assignment_is_unestimated($assign);

      push @ages, $now
        - DateTime::Format::ISO8601->parse_datetime($item->{updated_at})->epoch;
    }

    next CHK unless $total;

    my $avg_age = sum0(@ages) / @ages;

    my $summary = sprintf "%s %s: %u %s (avg. untouched time: %s)",
      $icon,
      ucfirst $label,
      $total,
      PL_N('task', $total),
      concise(duration($avg_age, 1));

    $summary .= sprintf ", %u unestimated", $unest if $unest;

    push @summaries, $summary;
  }

  my $text = join qq{\n}, @summaries;

  return Future->done([ $text, { slack => $text } ]);
}

my %Phase_Pos = (
  'Desired'   => 0,
  'Planning'  => 1,
  'Waiting'   => 2,
  'In Flight' => 3,
  'Long Haul' => 4,
  'Circling'  => 5,
  'Landing'   => 6,
);

sub project_report ($self, $who) {
  return unless my $lp_id = $who->lp_id;

  my $lpc = $self->lp_client_for_user($who);

  my $res = $lpc->query_items({
    filters => [
      [ item_type => '='  => 'Project'  ],
      [ owner_id  => '='  => $lp_id     ],
      [ is_done   => is   => 'false'    ],
      [ parent_id => '='  => $self->project_portfolio_id ],
      [ "custom_field:'Project Phase'" => 'is_set' ],
    ],
  });

  unless ($res->is_success) {
    $Logger->log("problems getting project report for " . $who->username);
    return;
  }

  my @projects =
    map  {; $_->[1] }
    sort {; ($Phase_Pos{ $a->[0] } // 99) <=> ($Phase_Pos{ $b->[0] } // 99) }
    map  {; [ $_->{custom_field_values}{'Project Phase'}, $_ ] }
    $res->payload_list;

  my @lines;
  for my $project (@projects) {
    my $phase = $project->{custom_field_values}{'Project Phase'};

    # Nothing to do here, generally..? -- rjbs, 2019-03-22
    next if $phase eq 'Desired' or $phase eq 'Waiting' or $phase eq 'Circling';

    my $shortcut = $project->{custom_field_values}{"Synergy Project Shortcut"};

    my $last_comment_ago = $self->_last_comment_ago($project);

    push @lines, join q{ },
      ($project->{custom_field_values}{Emoji} // "\N{FILE FOLDER}"),
      $self->_slack_item_link_with_name($project, {
        emoji => 0,
        lastcomment => 1,
      });
  }

  return unless @lines;

  my $text = join qq{\n}, "*—[ Project Lead ]—*", @lines;

  return Future->done([ $text, { slack => $text } ]);
}

sub iteration_report ($self, $who) {
  return unless my $lp_id = $who->lp_id;

  my $lpc = $self->lp_client_for_user($who);
  my @summaries;

  my $pkg_summary   = $self->_build_iteration_summary($lpc->current_iteration, $who);
  my $slack_summary = join qq{\n},
                      @summaries,
                      $self->_slack_pkg_summary($pkg_summary, $who->lp_id);

  my $reply = join qq{\n}, @summaries;

  return Future->done([
    $reply,
    {
      slack => $slack_summary,
    },
  ]);
}

sub reload_shortcuts ($self, $event) {
  $self->_set_projects($self->get_project_shortcuts);
  $self->_set_tasks($self->get_task_shortcuts);
  $event->reply("Shortcuts reloaded.");
  $event->mark_handled;
}

sub _build_iteration_summary ($self, $iteration, $user) {
  my $items_res = $self->lp_client_for_master->query_items({
    in    => $iteration->{package}{id},
    flags => { depth => -1 },
  });

  unless ($items_res->is_success) {
    $Logger->log([
      "error getting tree for iteration %s, package %s",
      $iteration->{number},
      $iteration->{package}{id},
    ]);
    return;
  }

  my $summary = summarize_iteration($iteration, $items_res->payload, $user->lp_id);
}

sub _slack_pkg_summary ($self, $summary, $lp_member_id) {
  my $text = "*—[ $summary->{name} ]—*\n";

  my $total = sum0 map {; 0 + ($summary->{$_} // [])->@* }
                   qw( containers tasks events others );

  unless ($total) {
    return "$text(no items)";
  }

  my %by_lp = map  {; $_->lp_id ? ($_->lp_id, $_->username) : () }
              $self->hub->user_directory->users;

  my @sparkles = grep {; $_->{name} =~ /\A✨/ } $summary->{tasks}->@*;
  my @tasks    = grep {; $_->{name} !~ /\A✨/ } $summary->{tasks}->@*;

  for my $c (@sparkles) {
    $text .= sprintf "%s %s\n",
      "✨",
      $self->_slack_item_link_with_name($c);
  }

  for my $c ($summary->{containers}->@*) {
    $text .= sprintf "%s %s%s (%u/%u)\n",
      ( $c->{type} eq 'Package' ? "\N{PACKAGE}"
      : $c->{type} eq 'Project' ? "\N{FILE FOLDER}"
      : $c->{type} eq 'Folder'  ? "\N{CARD INDEX DIVIDERS}"
      : $c->{type} eq 'Inbox'   ? "📫"
      :                           "❓"),

      $self->_slack_item_link_with_name($c),
      (($c->{owner_id} != $lp_member_id)
        ? (" _(for @{[ $by_lp{$c->{owner_id}} // 'someone else']})_")
        : q{}),

      $c->{done_tasks},
      $c->{total_tasks},
      ;
  }

  for my $c (@tasks) {
    $text .= sprintf "%s %s\n",
      "🌀",
      $self->_slack_item_link_with_name($c);
  }

  for my $c ($summary->{events}->@*) {
    $text .= sprintf "%s %s\n",
      "📅",
      $self->_slack_item_link_with_name($c),
  }

  for my $c ($summary->{others}->@*) {
    $text .= sprintf "%s %s (%s)\n",
      "⁉️",
      $self->_slack_item_link_with_name($c),
      $c->{type};
  }

  if (
    defined $summary->{page_count}
    && $summary->{page_count} != $summary->{page}
  ) {
    $text .= "(page $summary->{page} of $summary->{page_count})\n";
  }

  chomp $text;
  return $text;
}

sub summarize_iteration ($iteration, $item, $member_id) {
  my @containers;
  my @events;
  my @tasks;
  my @others;

  CHILD: for my $c (@{ $item->{children} // []}) {
    next CHILD unless $c->{assignments};

    if ($c->{type} eq 'Task') {
      my ($assign) = grep {; $_->{person_id} == $member_id }
                     $c->{assignments}->@*;

      next unless $assign;

      # If the user's assignment was done before this iteration started,
      # pretend it isn't even here. -- rjbs, 2019-02-27
      next if $assign->{done_on} && $assign->{done_on} lt $iteration->{start};

      push @tasks, {
        id        => $c->{id},
        type      => $c->{type},
        name      => $c->{name},
        is_done   => $c->{is_done},
      };

      next CHILD;
    }

    if ($c->{type} eq 'Project' or $c->{type} eq 'Package') {
      my $summary = {
        id        => $c->{id},
        type      => $c->{type},
        name      => $c->{name},
        is_done   => $c->{is_done},
        owner_id  => $c->{assignments}[0]{person_id},

        total_tasks => 0,
        done_tasks  => 0,
      };

      summarize_container($iteration, $c, $summary, $member_id);

      next CHILD unless $summary->{total_tasks}
                 or     $summary->{owner_id} == $member_id;

      push @containers, $summary;
      next CHILD;
    }

    # I don't think can ever happen, but let's Be Prepared. -- rjbs, 2018-06-15
    {
      my ($assign) = grep {; $_->{person_id} == $member_id }
                     $c->{assignments}->@*;

      next CHILD unless $assign;

      if ($c->{type} eq 'Event') {
        push @events, {
          id        => $c->{id},
          type      => $c->{type},
          name      => $c->{name},
          is_done   => $c->{is_done},
        };
      } else {
        push @others, {
          id        => $c->{id},
          type      => $c->{type},
          name      => $c->{name},
          is_done   => $c->{is_done},
        };
      }
    }
  }

  @containers = sort {
    # projects before packages
    return -1 if $a->{type} eq 'Project' and $b->{type} ne 'Project';
    return  1 if $b->{type} eq 'Project' and $a->{type} ne 'Project';
    # owned-by-self before owned-by-other
    return -1 if  $a->{owner_id} == $member_id
              and $b->{owner_id} != $member_id;
    return 1  if  $b->{owner_id} == $member_id
              and $a->{owner_id} != $member_id;

    # TODO: then by task priority, but actually here I have implemented by name
    # because it's easier for now -- rjbs, 2018-06-21
    return fc $a->{name} cmp fc $b->{name};
  } @containers;

  return {
    name        => $item->{name},
    containers  => \@containers,
    tasks       => \@tasks,
    (@events ? (events => \@events) : ()),
    (@others ? (others => \@others) : ()),
  };
}

sub summarize_container ($iteration, $item, $summary, $member_id) {
  CHILD: for my $c (@{ $item->{children} // []}) {
    if ($c->{type} eq 'Task') {
      my ($assign) = grep {; $_->{person_id} == $member_id }
                     $c->{assignments}->@*;

      next CHILD unless $assign;

      # If the user's assignment was done before this iteration started,
      # pretend it isn't even here. -- rjbs, 2019-02-27
      next if $assign->{done_on} && $assign->{done_on} lt $iteration->{start};

      $summary->{total_tasks}++;
      $summary->{done_tasks}++ if $assign->{is_done};
      next CHILD;
    }

    summarize_container($iteration, $c, $summary, $member_id);
  }

  return;
}

__PACKAGE__->add_preference(
  name      => 'api-token',
  validator => sub ($self, $value, @) { return $value },
  describer => sub ($value) { return defined $value ? "<redacted>" : '<undef>' },
  default   => undef,
);

__PACKAGE__->add_preference(
  name      => 'should-nag',
  validator => sub ($self, $value, @) { return bool_from_text($value) },
  default   => 0,
);

__PACKAGE__->add_preference(
  name        => 'default-project-shortcut',
  validator   => sub ($self, $value, @) {
    return unless $value && length $value;
    $value =~ s/\A#//;
    return unless $value =~ /\A[-a-z]+\z/;
    return $value;
  },
  describer   => sub ($value) { return $value // '<undef>' },
  default     => undef,
  description => 'the project shortcut to which tasks for this user will default',
);

# Temporary, presumably. We're assuming here that the values from git are
# valid.
sub load_preferences_from_user ($self, $username) {
  $Logger->log_debug([ "Loading LiquidPlanner preferences for %s", $username ]);
  my $user = $self->hub->user_directory->user_named($username);

  $self->set_user_preference($user, 'should-nag', $user->should_nag)
    unless $self->user_has_preference($user, 'should-nag');
}

sub user_status_for ($self, $event, $user) {
  return unless $self->auth_header_for($user);

  my $reply = qw{};

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;
  if ($timer_res->is_success && $timer_res->payload) {
    my $lp_timer = $timer_res->payload;
    my $item_res = $lpc->get_item($lp_timer->item_id);
    if ($item_res->is_success) {
      $reply .= sprintf "LiquidPlanner timer running for %s (total %s) on LP %s: %s",
        $lp_timer->running_time_duration,
        $lp_timer->real_total_time_duration,
        $lp_timer->item_id,
        $item_res->payload->{name};
    }
  }

  my $event_res = $lpc->query_items({
    flags   => { flat => 1 },
    filters => [
      [ item_type => '=' => 'Event' ],
      [ is_done   => is  => 'false' ],
    ],
  });

  my $now = DateTime->now(time_zone => 'UTC')->iso8601;
  if ($event_res->is_success) {
    my @events;
    my %seen;
    for my $item ($event_res->payload_list) {
      next if $seen{ $item->{id} }++;

      my ($assign) = grep {; $_->{person_id} == $user->lp_id }
                     $item->{assignments}->@*;

      next unless $assign;
      next unless $assign->{expected_start}  le $now;
      next unless $assign->{expected_finish} ge $now;
      $reply .= qq{\n} if $reply;
      $reply .= "LiquidPlanner event: $item->{name}";
    }
  }

  return undef unless length $reply;

  return $reply;
}

sub _handle_contents ($self, $event, $rest) {
  my $lpc = $self->lp_client_for_user($event->from_user);

  $event->mark_handled;

  my ($what, $more) = split /\s+/, $rest, 2;

  my $page = 1;
  if (length $more) {
    unless ($more =~ m{\Apage:([0-9]+)\z}) {
      return $event->error_reply(q{You can only say "contents THING" optionally followed by "page:N".});
    }

    $page = 0 + $1;

    unless ($page > 0 and $page < 10_000) {
      return $event->error_reply(q{That page number didn't make sense to me.});
    }
  }

  my $item;

  if ($what =~ /\A#(.+)/) {
    ($item, my $err) = $self->project_for_shortcut("$1");

    return $event->error_reply($err) if $err;
  } elsif ($what =~ /\A[0-9]+\z/) {
    my $item_res = $lpc->get_item($what);

    return $event->reply("I can't find an item with that id!")
      unless $item = $item_res->payload;
  } else {
    return $event->error_reply(q{You can only say "contents ID" or "contents #shortcut".});
  }

  my $res = $lpc->query_items({
    in    => $item->{id},
    flags => {
      depth => 1,
    },
    filters => [
      [ is_done => 'is', 'false' ],
    ],
  });

  return $event->error_reply("Sorry, I couldn't get the contents.")
    unless $res->is_success;

  my @items = grep {; $_->{id} != $item->{id} } $res->payload_list;

  my $summary = $self->_summarize_item_list(\@items, {
    title => $item->{name},
    page  => $page
  });

  my $slack_summary = $self->_slack_pkg_summary($summary, -1);

  return $event->reply(
    "(this is only useful on Slack for now)",
    {
      slack => $slack_summary,
    },
  );
}

sub _summarize_item_list ($self, $items, $arg) {
  my $page  = $arg->{page} // 1;
  my $total = @$items;

  @$items = splice @$items, 10 * ($page - 1), 10;

  my $pkg_summary = {
    name       => $arg->{title},
    page       => $page,
    page_count => ceil($total / 10),
    containers => [ grep {; $_->{type} =~ /\A Project | Package | Folder \z/x } @$items ],
    tasks      => [ grep {; $_->{type} eq 'Task' } @$items ],
    events     => [ grep {; $_->{type} eq 'Event' } @$items ],
    others     => [ grep {; $_->{type} !~ /\A Project | Package | Folder | Task | Event \z/x } @$items ],
  };
}

1;
