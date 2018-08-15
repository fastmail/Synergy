use v5.24.0;
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
use JSON 2 ();
use Time::Duration;
use Time::Duration::Parse;
use Synergy::Logger '$Logger';
use Synergy::LPC; # LiquidPlanner Client, of course
use Synergy::Timer;
use Synergy::Util qw(parse_time_hunk pick_one bool_from_text);
use DateTime;
use DateTime::Format::ISO8601;
use utf8;

my $JSON = JSON->new->utf8;

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

has workspace_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has activity_id => (
  is  => 'ro',
  isa => 'Int',
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

sub _slack_item_link_with_name ($self, $item) {
  state $shortcut_prefix = { Task => '*', Project => '#' };
  my $type = $item->{type};
  my $shortcut = $item->{custom_field_values}{"Synergy $type Shortcut"};

  my $title = $item->{name};
  $title .= " *\x{0200B}$shortcut_prefix->{$type}$shortcut*" if $shortcut;

  my $urgent = $self->urgent_package_id;

  sprintf "<%s|LP>\N{THIN SPACE}%s %s %s",
    $self->item_uri($item->{id}),
    $item->{id},
    ( $item->{is_done} ? "✓"
    : (grep {; $_ == $urgent } $item->{package_ids}->@*) ? "\N{FIRE}"
    : "•"
    ),
    $title;
}

has [ qw( inbox_package_id urgent_package_id recurring_package_id ) ] => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

my %KNOWN = (
  '++'      =>  [ \&_handle_plus_plus,
                  "++ TASK-SPEC: add a task for yourself" ],
  '>>'      =>  [ \&_handle_angle_angle,
                  ">> USER TASK-SPEC: add a task for someone else "],
  abort     =>  [ \&_handle_abort,
                  "abort timer: throw your LiquidPlanner timer away" ],
  chill     =>  [ \&_handle_chill,
                  "chill: do not nag about a timer until you say something new",
                  "chill until WHEN: do not nag until the designated time",
                  ],
  commit    =>  [ \&_handle_commit,
                  "commit [COMMENT]: commit your LiquidPlanner timer, with optional comment",
                ],

  contents  =>  [ \&_handle_contents,
                  "contents CONTAINER: show what's in a package or project",
                ],

  done      =>  [ \&_handle_done,
                  "done: commit your LiquidPlanner task and mark your work done",
                ],
  expand    =>  [ \&_handle_expand ],
  good      =>  [ \&_handle_good   ],
  gruß      =>  [ \&_handle_good   ],
  inbox     =>  [ \&_handle_inbox,
                  "inbox [PAGE-NUMBER]: list the tasks in your inbox",
                ],
  last      =>  [ \&_handle_last   ],
  projects  =>  [ \&_handle_projects,
                  "projects: list all known project shortcuts",
                ],
  recurring =>  [ \&_handle_recurring,
                  "recurring [PAGE-NUMBER]: list your tasks in Recurring Tasks",
                ],
  reset     =>  [ \&_handle_reset,
                  "reset timer: set your timer back to zero, but leave it running",
                ],
  restart   =>  [ \&_handle_resume ],
  resume    =>  [ \&_handle_resume,
                  "resume timer: start the last time you had running up again",
                ],

  search    =>  [ \&_handle_search,
                  join("\n",
                    "search SEARCH_TERM: find tasks in LiquidPlanner matching term",
                    "Additional search flags include:",
                    "• `done:1`, search for completed tasks",
                    "• `project:PROJECT`, search in this project shortcut",
                    "• `page:N`, get the Nth page of 10 results",
                    "• `type:TYPE`, pick what type of thing to find (package, project, task)",
                    "• `user:NAME`, tasks owned by the user named NAME",
                  ),
                ],

  shows     =>  [ \&_handle_shows,       ],
  "show's"  =>  [ \&_handle_shows,       ],
  showtime  =>  [ \&_handle_showtime,    ],
  spent     =>  [ \&_handle_spent,
                  "spent TIME on THING: log time against a task (either TASK-SPEC or TASK-ID)",
                ],
  start     =>  [ \&_handle_start,
                  "start TASK-ID: start your timer on the given task",
                ],
  stop      =>  [ \&_handle_stop,
                  "stop timer: stop your timer, but keep the time on it",
                ],
  task      =>  [ \&_handle_task,        ],
  tasks     =>  [ \&_handle_tasks,
                  "tasks [PAGE-NUMBER]: list your scheduled work",
                ],
  timer     =>  [ \&_handle_timer,
                  "timer: show your current LiquidPlanner timer (if any)",
                ],
  todo      =>  [ \&_handle_todo,        ],
  todos     =>  [ \&_handle_todos,       ],
  urgent    =>  [ \&_handle_urgent,
                  "urgent [PAGE-NUMBER]: list your urgent tasks",
                ],
  zzz       =>  [ \&_handle_triple_zed,  ],
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

        my ($what) = $event->text =~ /^([^\s]+)\s?/;
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
      name      => "reload-shortcuts",
      method    => "reload_shortcuts",
      predicate => sub ($, $e) {
        $e->was_targeted &&
        $e->text =~ /^reload\s+shortcuts\s*$/i;
      },
    },
    {
      name      => "damage-report",
      method    => "damage_report",
      predicate => sub ($, $e) {
        $e->was_targeted &&
        $e->text =~ /^\s*(damage\s+)?report(\s+for\s+([a-z]+))?\s*$/in;
      },
      help_entries => [
        {
          title => "report",
          text => "report [for USER]: show the user's current LiquidPlanner workload",
        }
      ],
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
    $event->reply("Sorry, I don't know who you are.");
    $event->mark_handled;
    return 1;
  }

  # existing hacks for massaging text
  my $text = $event->text;
  $text = "show's over" if $text =~ /\A\s*show’s\s+over\z/i;    # curly quote
  $text = "good day_au" if $text =~ /\A\s*g'day(?:,?\s+mate)?[1!.?]*\z/i;
  $text = "good day_de" if $text =~ /\Agruß gott[1!.]?\z/i;
  $text =~ s/\Ago{3,}d(?=\s)/good/;
  $text =~  s/^done, /done /;   # ugh

  my ($what, $rest) = split /\s+/, $text, 2;
  $what &&= lc $what;

  # we can be polite even to non-lp-enabled users
  return $self->_handle_good($event, $rest) if $what eq 'good';

  unless ($self->auth_header_for($event->from_user)) {
    $event->mark_handled;
    $event->reply($ERR_NO_LP);
    return 1;
  }

  $event->mark_handled;
  return $KNOWN{$what}[0]->($self, $event, $rest)
}

sub provide_lp_link ($self, $event) {
  my $user = $event->from_user;
  return unless $user && $self->auth_header_for($user);

  state $lp_id_re       = qr/\bLP([1-9][0-9]{5,10})\b/i;
  state $lp_shortcut_re = qr/\bLP([*#][-_a-z0-9]+)\b/i;

  my $workspace_id  = $self->workspace_id;
  my $lp_url_re     = qr{\b(?:\Qhttps://app.liquidplanner.com/space/$workspace_id\E/.*/)([0-9]+)P?/?\b};

  my $lpc = $self->lp_client_for_user($user);
  my $item_id;

  if (
    $event->was_targeted
    && ($event->text =~ /\A\s* $lp_id_re \s*\z/x
    ||  $event->text =~ /\A\s* $lp_shortcut_re \s*\z/x)
  ) {
    # do better than bort
    $event->mark_handled;
  }

  my @ids = $event->text =~ /$lp_id_re/g;
  push @ids, $event->text =~ /$lp_url_re/g;

  while (my $shortcut = $event->text =~ /$lp_shortcut_re/g) {
    my $method = ((substr $shortcut, 0, 1, q{}) eq '*' ? 'task' : 'project')
               . '_for_shortcut';

    my ($item, $error)  = $self->$method($shortcut);
    return $event->reply($error) unless $item;

    push @ids, $item->{id};
  }

  return unless @ids;

  ITEM: for my $item_id (@ids) {
    my $item_res = $lpc->get_item($item_id);

    unless ($item_res->is_success) {
      $event->reply("Sorry, something went wrong looking for LP$item_id.");
      next ITEM;
    }

    my $item;
    unless ($item = $item_res->payload) {
      $event->reply("I can't find anything for LP$item_id.");
      next ITEM;
    }

    my $name = $item->{name};

    my $reply;

    if ($item->{type} =~ /\A Task | Package | Project \z/x) {
      my $icon = $item->{type} eq 'Task'    ? "" # Sometimes 🌀
               : $item->{type} eq 'Package' ? "📦"
               : $item->{type} eq 'Project' ? "📁"
               :                              "($item->{type})";

      my $uri = $self->item_uri($item_id);

      $event->reply(
        "$icon LP$item_id: $item->{name} ($uri)",
        {
          slack => sprintf '%s %s',
            $icon, $self->_slack_item_link_with_name($item),
        },
      );
    } else {
      $event->reply("LP$item_id: is a $item->{type}");
    }
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
    $event->reply("You're back!  No longer chilling.")
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
      if ($lp_timer && $lp_timer->{running_time} > 3) {
        if ($last_nag && time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }

        my $msg = "Your timer has been running for "
                . concise(duration($lp_timer->{running_time} * 3600))
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

  my $lpc = $self->lp_client_for_master;
  my $res = $lpc->query_items({
    filters => [
      [ item_type => '='  => $type    ],
      [ is_done   => is   => 'false'  ],
      [ "custom_field:'Synergy $type Shortcut'" => 'is_set' ],
    ],
  });

  return {} unless $res->is_success;

  my %dict;
  my %seen;

  for my $item ($res->payload_list) {
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

sub lp_client_for_user ($self, $user) {
  Synergy::LPC->new({
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

sub lp_client_for_master ($self) {
  my ($master) = $self->hub->user_directory->master_users;

  Carp::confess("No master users configured") unless $master;

  $self->lp_client_for_user($master);
}

sub _handle_last ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->reply($ERR_NO_LP)
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

sub _handle_timer ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->reply($ERR_NO_LP)
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

  my $time = concise( duration( $timer->{running_time} * 3600 ) );

  my $task_res = $lpc->get_item($timer->{item_id});

  my $task = ($task_res->is_success && $task_res->payload)
          || { id => $timer->{item_id}, name => '??' };

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
     ||  $text =~ s/\s*(#[a-z0-9]+)\s*\z//i
  ) {
    my $hunk = $1;
    if ($hunk =~ s/^#//) {
      $flag{project}{$hunk} = 1;
      next;
    } elsif ($hunk =~ /[!>]/) {
      $flag{urgent} ++ if $hunk =~ /!/;
      $flag{start}  ++ if $hunk =~ />/;
      next;
    } else {
      $flag{urgent} ++ if $hunk =~ $urgent_emoji;
      $flag{start}  ++ if $hunk =~ $start_emoji;
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

  if ($plan->{urgent}) {
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
                    map  {; $_->default_project_shortcut }
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
    $rest = join qq{\n}, @lines;

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

    for my $cmd_line (@cmd_lines) {
      my @cmd_strs = split m{(?:^|\s+)/}m, $cmd_line;
      shift @cmd_strs; # the leading / means the first entry is always q{}

      CMDSTR: for my $cmd_str (@cmd_strs) {
        my ($cmd, $rest) = split /\s+/, $cmd_str, 2;

        $cmd = $alias{$cmd} if $alias{$cmd};

        my $method = $self->can("_task_subcmd_$cmd");
        unless ($method) {
          push @bad_cmds, $cmd_str;
          next CMDSTR;
        }

        if (my $error = $self->$method($rest, $plan)) {
          push @errors, $error;
        }
      }
    }

    if (@errors or @bad_cmds) {
      $error->{rest} = @errors ? (join q{  }, @errors) : q{};
      if (@bad_cmds) {
        $error->{rest} .= "  " if $error->{rest};
        $error->{rest} .= "Bogus commands: " . join q{ -- }, sort @bad_cmds;
      }
    }

    return if $error->{rest};
  }

  $plan->{description} = sprintf '%screated by %s in response to %s%s',
    ($rest ? "$rest\n\n" : ""),
    $self->hub->name,
    $via,
    $uri ? "\n\n$uri" : "";
}

sub _task_subcmd_urgent ($self, $rest, $plan) {
  return "The /urgent command takes no arguments." if $rest;
  $plan->{urgent} = 1;
  return;
}

sub _task_subcmd_start ($self, $rest, $plan) {
  return "The /start command takes no arguments." if $rest;
  $plan->{start} = 1;
  return;
}

sub _task_subcmd_estimate ($self, $rest, $plan) {
  my ($low, $high) = split /\s*-\s*/, $rest, 2;
  $high //= $low;
  s/^\s+//, s/\s+$//, s/^\./0./, s/([0-9])$/$1h/ for $low, $high;
  my $low_s  = eval { parse_duration($low); };
  my $high_s = eval { parse_duration($high); };

  if (defined $low_s && defined $high_s) {
    $plan->{estimate} = { low => $low_s / 3600, high => $high_s / 3600 };
    return;
  }

  return qq{I couldn't understand the /assign estimate "$rest".}
}

sub _task_subcmd_project ($self, $rest, $plan) {
  return qq{You used /project without a project shortcut.} unless $rest;
  $plan->{project}{$rest} = 1;
  return;
}

sub _task_subcmd_assign ($self, $rest, $plan) {
  return qq{You used /assign without any usernames.} unless $rest;
  push $plan->{usernames}->@*, split /\s+/, $rest;
  return;
}

sub _task_subcmd_done ($self, $rest, $plan) {
  return qq{The /done command takes no arguments.} if $rest;
  $plan->{done} = 1;
  return;
}

sub _task_subcmd_log ($self, $rest, $plan) {
  my $dur = $rest;

  s/^\s+//, s/\s+$//, s/^\./0./, s/([0-9])$/$1h/ for $dur;
  my $secs = eval { parse_duration($dur) };

  return qq{I couldn't understand the /log duration "$rest".}
    unless defined $secs;

  if ($secs > 12 * 86_400) {
    my $dur_restr = duration($secs);
    return qq{You said to spend "$rest" which I read as $dur_restr.  }
         . qq{That's too long!};
  }

  $plan->{log_hours} = $secs / 3600;
  return;
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

  $self->_check_plan_rest($event, \%plan, \%error);
  $self->_check_plan_usernames($event, \%plan, \%error) if $plan{usernames};
  $self->_check_plan_project($event, \%plan, \%error)   if $plan{project};

  $error{name} = "That task name is just too long!  Consider putting more of it in the long description."
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
    return $event->reply("Does not compute.  Usage:  task for TARGET: TASK");
  }

  my @target_names = split /(?:\s*,\s*|\s+and\s+)/, $target;

  my ($plan, $error) = $self->task_plan_from_spec(
    $event,
    {
      usernames => [ @target_names ],
      text      => $spec_text,
    },
  );

  $self->_execute_task_plan($event, $plan, $error);
}

sub _execute_task_plan ($self, $event, $plan, $error) {
  if ($error) {
    my $errors = join q{  }, values %$error;
    return $event->reply($errors);
  }

  my $lpc = $self->lp_client_for_user($event->from_user);

  my $arg = {};

  my $task = $self->_create_lp_task($event, $plan, $arg);

  unless ($task) {
    if ($arg->{already_notified}) {
      return;
    } else {
      return $event->reply(
        "Sorry, something went wrong when I tried to make that task.",
        $arg,
      );
    }
  }

  my $reply_base = "created, assigned to "
                 . join q{ and }, map {; $_->username } $plan->{owners}->@*;

  if ($plan->{start}) {
    my $res = $lpc->start_timer_for_task_id($task->{id});

    if ($res->is_success) {
      $self->set_last_lp_timer_task_id_for_user($event->from_user, $task->{id});

      $reply_base .= q{, timer started};
    } else {
      $reply_base .= q{, but the timer couldn't be started};
    }
  }

  if (my $log_hrs = $plan->{log_hours}) {
    my $track_ok = $lpc->track_time({
      task_id => $task->{id},
      work => $log_hrs,
      done => $plan->{done},
      member_id   => $event->from_user->lp_id,
      activity_id => $task->{activity_id},
    });

    if ($track_ok) {
      my $time = sprintf '%0.2fh', $log_hrs;
      $reply_base .= ".  I logged $time for you";
      $reply_base .= " and marked your work done" if $plan->{done};
    } else {
      $reply_base .= ".  I couldn't log time it";
    }
  } elsif ($plan->{done}) {
    my $track_ok = $lpc->track_time({
      task_id => $task->{id},
      work => 0,
      done => $plan->{done},
      member_id   => $event->from_user->lp_id,
      activity_id => $task->{activity_id},
    });

    if ($track_ok) {
      $reply_base .= ".  I marked your work done";
    } else {
      $reply_base .= ".  I couldn't mark your work done";
    }
  }

  my $item_uri = $self->item_uri($task->{id});

  my $plain = join qq{\n},
    "LP$task->{id} $reply_base.",
    "\N{LINK SYMBOL} $item_uri",
    "\N{LOVE LETTER} " . $task->{item_email};

  my $slack = sprintf "%s %s. (<mailto:%s|email>)",
    $self->_slack_item_link($task),
    $reply_base,
    $task->{item_email};

  $event->reply($plain, { slack => $slack });
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

sub lp_tasks_for_user ($self, $user, $count, $which='tasks', $arg = {}) {
  my $lpc = $self->lp_client_for_user($user);

  my $res = $lpc->upcoming_tasks_for_member_id($user->lp_id);

  return unless $res->is_success;

  my @tasks = grep {; $_->{type} eq 'Task' } $res->payload_list;

  if ($which eq 'tasks') {
    @tasks = grep {;
      (! grep { $self->inbox_package_id == $_ } $_->{parent_ids}->@*)
      &&
      (! grep { $self->inbox_package_id == $_ } $_->{package_ids}->@*)
    } @tasks;
  } else {
    my $method = "$which\_package_id";
    my $package_id = $self->$method;
    unless ($package_id) {
      $Logger->log("can't find package_id for '$which'");
      return;
    }

    @tasks = grep {;
      (grep { $package_id == $_ } $_->{parent_ids}->@*)
      ||
      (grep { $package_id == $_ } $_->{package_ids}->@*)
    } @tasks;
  }

  splice @tasks, $count;

  unless ($arg->{no_prefix}) {
    my $urgent = $self->urgent_package_id;
    for (@tasks) {
      $_->{name} = "[URGENT] $_->{name}"
        if (grep { $urgent == $_ } $_->{parent_ids}->@*)
        || (grep { $urgent == $_ } $_->{package_ids}->@*);
    }
  }

  return \@tasks;
}

sub _send_task_list ($self, $event, $tasks, $arg = {}) {
  my $reply = q{};
  my $slack = q{};

  for my $task (@$tasks) {
    my $uri = $self->item_uri($task->{id});
    $reply .= "$task->{name} ($uri)\n";
    $slack .= $self->_slack_item_link_with_name($task) . "\n";
  }

  chomp $reply;
  chomp $slack;

  my $method = $arg->{public} ? 'reply' : 'private_reply';
  $event->$method($reply, { slack => $slack });
}

sub _handle_tasks ($self, $event, $text) {
  my $user = $event->from_user;
  my ($how_many) = $text =~ /\Atasks\s+([0-9]+)\z/;

  my $per_page = 5;
  my $page = $how_many && $how_many > 0 ? $how_many : 1;

  unless ($page <= 10) {
    return $event->reply(
      "If it's not in your first ten pages, better go to the web.",
    );
  }

  my $count = $per_page * $page;
  my $start = $per_page * ($page - 1);

  my $lp_tasks = $self->lp_tasks_for_user($user, $count, 'tasks');
  my @task_page = splice @$lp_tasks, $start, $per_page;

  return $event->reply("You don't have any open tasks right now.  Woah!")
    unless @task_page;

  $self->_send_task_list($event, \@task_page);

  $event->reply("Responses to <tasks> are sent privately.") if $event->is_public;
}

sub _parse_search ($self, $text) {
  my @words;
  my %flag = ();

  state $prefix_re  = qr{!?\^?};
  state $ident_re   = qr{[-a-zA-Z][-_a-zA-Z0-9]*};

  my $last = q{};
  TOKEN: while (length $text) {
    $text =~ s/^\s+//;

    # Abort!  Shouldn't happen. -- rjbs, 2018-06-30
    if ($last eq $text) {
      $flag{parse_error} = 1;
      last TOKEN;
    }
    $last = $text;

    if ($text =~ s/^($prefix_re)"( (?: \\" | [^"] )+ )"\s*//x) {
      my ($prefix, $word) = ($1, $2);

      push @words, {
        word => ($word =~ s/\\"/"/gr),
        op   => ( $prefix eq ""   ? "contains"
                : $prefix eq "^"  ? "starts_with"
                : $prefix eq "!^" ? "does_not_start_with"
                : $prefix eq "!"  ? "does_not_contain" # fake operator
                :                   undef),
      };

      next TOKEN;
    }

    if ($text =~ s/^\#($ident_re)(?: \s | \z)//x) {
      $flag{ project }{$1}++;
      next TOKEN;
    }

    if ($text =~ s/^($ident_re):([0-9]+|$ident_re)(?: \s | \z)//x) {
      $flag{$1}{$2}++;
      next TOKEN;
    }

    {
      # Just a word.
      ((my $token), $text) = split /\s+/, $text, 2;
      $token =~ s/\A($prefix_re)//;
      my $prefix = $1;
      push @words, {
        word => $token,
        op   => ( $prefix eq ""   ? "contains"
                : $prefix eq "^"  ? "starts_with"
                : $prefix eq "!^" ? "does_not_start_with"
                : $prefix eq "!"  ? "does_not_contain" # fake operator
                :                   undef),
      };
    }
  }

  return {
    words => \@words,
    flags => \%flag,
  }
}

sub _handle_search ($self, $event, $text) {
  my $search = $self->_parse_search($text);

  my %flag  = $search->{flags}->%*;
  my @words = $search->{words}->@*;

  if ($search->{flags}{parse_error}) {
    return $event->reply("Your search blew my mind, and now I am dead.");
  }

  my %error;

  my %qflag = (flat => 1, depth => -1);
  my @filters;
  my $has_strong_check = 0;

  if (my $done = delete $flag{done}) {
    my @values = keys %$done;
    if (@values > 1) {
      $error{done} = qq{You gave more than one "done" value.};
    } else {
      push @filters, [ 'is_done', 'is', ($values[0] ? 'true' : 'false') ];
    }
  } else {
    push @filters, [ 'is_done', 'is', 'false' ];
  }

  if (my $proj = delete $flag{project}) {
    my @values = keys %$proj;
    if (@values > 1) {
      $error{project} = "You can only limit by one project at a time.";
    } else {
      my ($project, $err) = $self->project_for_shortcut($values[0]);

      if ($project) {
        $has_strong_check++;
        push @filters, [ 'project_id', '=', $project->{id} ];
      } else {
        $error{project} = $err;
      }
    }
  }

  my ($limit, $offset) = (11, 0);
  if (my $page = delete $flag{page}) {
    my @values = keys %$page;
    if (@values > 1) {
      $error{page} = "You asked for more than one distinct page number.";
    } else {
      my $value = $values[0];
      if ($value !~ /\A[1-9][0-9]*\z/) {
        $error{page} = "You have to pick a positive integer page number.";
      } elsif ($value > 10) {
        $error{page} = "Sorry, you can't get a page past the tenth.";
      } else {
        $offset = ($value - 1) * 10;
        $limit += $offset;
      }
    }
  }
  $qflag{limit} = $limit;

  if (my $owners = delete $flag{user}) {
    my %member;
    my %unknown;
    for my $who (keys %$owners) {
      my $target = $self->resolve_name($who, $event->from_user);
      my $lp_id  = $target && $target->lp_id;

      if ($lp_id) { $member{$lp_id}++ }
      else        { $unknown{$who}++ }
    }

    if (%unknown) {
      $error{user} = "I don't know who these users are: "
                   . join q{, }, sort keys %unknown;
    } else {
      push @filters, map {; [ 'owner_id', '=', $_ ] } keys %member;
    }
  }

  my $item_type;
  if (my $type = delete $flag{type}) {
    my (@types) = keys %$type;

    if (@types > 1) {
      $error{type} = "You can only filter on one type at a time.";
    } else {
      my $got_type = fc $types[0];
      if ($got_type =~ /\A project | task | package \z/x) {
        $item_type = ucfirst $got_type;
      } else {
        $error{type} = qq{I don't know what a "$got_type" type item is.};
      }
    }
  }
  $item_type //= 'Task';
  push @filters, [ 'item_type', 'is', $item_type ];

  my $debug = $flag{debug} && grep { $_ } keys((delete $flag{debug})->%*);

  if (keys %flag) {
    $error{unknown} = "You used some flags I don't understand: "
                    . join q{, }, sort keys %flag;
  }

  WORD: for my $word (@words) {
    if ($word->{op} eq 'does_not_contain') {
      $error{word_dnc} = qq{Annoyingly, there's no "does not contain" }
                       . qq{query in LiquidPlanner, so you can't use "!" }
                       . qq{as a prefix.};
      next WORD;
    }

    if (! defined $word->{op}) {
      $error{word_dnc} = qq{Something weird happened with your search.};
      next WORD;
    }

    # You need to have some kind of actual search.
    $has_strong_check++ unless $word->{op} eq 'does_not_start_with';

    push @filters, [ 'name', $word->{op}, $word->{word} ];
  }

  unless ($has_strong_check) {
    $error{strong} = "Your search has to be limited to one project or "
                   . "have at least one non-negated search term.";
  }

  if (%error) {
    return $event->reply(join q{  }, sort values %error);
  }

  if ($debug) {
    $event->reply(
      "I'm going to run this query:\n"
      . JSON->new->canonical->encode({ %qflag, filters => \@filters }),
    );
  }

  my $check_res = $self->lp_client_for_user($event->from_user)->query_items({
    %qflag,
    filters => \@filters,
  });

  return $event->reply("Something went wrong when running that search.")
    unless $check_res->is_success;

  my %seen;
  my @tasks = grep {; ! $seen{$_->{id}}++ } $check_res->payload_list;

  return $event->reply("Nothing matched that search.") unless @tasks;

  # fix and more to live in send-task-list
  my $total = @tasks;
  @tasks = splice @tasks, $offset, 10;

  return $event->reply("That's past the last page of results.") unless @tasks;

  $self->_send_task_list($event, \@tasks, { public => 1 });
}

sub _handle_task_list ($self, $event, $cmd, $count) {
  my $user = $event->from_user;

  my $arg = $cmd eq 'urgent' ? { no_prefix => 1 } : {};
  my $lp_tasks = $self->lp_tasks_for_user($user, $count, $cmd, $arg);

  unless (@$lp_tasks) {
    my $suffix = $cmd =~ /(inbox|urgent)/n
               ? ' \o/'
               : '';
    $event->reply("You don't have any open $cmd tasks right now.$suffix");
    return;
  }

  $self->_send_task_list($event, $lp_tasks);
  $event->reply("Responses to <$cmd> are sent privately.") if $event->is_public;
}

sub _handle_inbox ($self, $event, $text) {
  return $self->_handle_task_list($event, 'inbox', 200);
}

sub _handle_urgent ($self, $event, $text) {
  return $self->_handle_task_list($event, 'urgent', 100);
}

sub _handle_recurring ($self, $event, $text) {
  return $self->_handle_task_list($event, 'recurring', 100);
}

sub _handle_plus_plus ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  unless (length $text) {
    return $event->reply("Thanks, but I'm only as awesome as my creators.");
  }

  my $who     = $event->from_user->username;
  my $pretend = "task for $who: $text";

  if ($text =~ /\A\s*that\s*\z/) {
    my $last  = $self->get_last_utterance($event->source_identifier);

    unless (length $last) {
      return $event->reply("I don't know what 'that' refers to.");
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
  return $event->reply($prefix . "You don't have an expando for <$expand_target>")
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
    package_id  => $my_arg->{urgent}
                ? $self->urgent_package_id
                : $self->inbox_package_id,
    parent_id   => $my_arg->{project_id}
                ?  $my_arg->{project_id}
                :  undef,
  );

  $container{parent_id} = delete $container{package_id}
    unless $container{parent_id};

  my sub assignment ($who) {
    my %est = $my_arg->{estimate}
            ? (low_effort_remaining  => $my_arg->{estimate}{low},
               high_effort_remaining => $my_arg->{estimate}{high})
            : ();

    return {
      person_id => $who->lp_id,
      %est,
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
  my $lpc = $self->lp_client_for_user($as_user);

  my $res = $lpc->create_task($payload);

  return unless $res->is_success;

  return $res->payload;
}

sub lp_timer_for_user ($self, $user) {
  return unless $self->auth_header_for($user);

  my $timer_res = $self->lp_client_for_user($user)->my_running_timer;

  return unless $timer_res->is_success;

  my $timer = $timer_res->payload;

  if ($timer) {
    $self->set_last_lp_timer_task_id_for_user($user, $timer->{item_id});
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
    if $text =~ /\s*over\s*[+!.]*\s*/i;

  return;
}

sub _handle_chill ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->reply($ERR_NO_LP)
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
  return $event->reply("Sorry, I couldn't parse '$text' into a time")
    unless $time;

  my $when = DateTime->from_epoch(
    time_zone => $user->time_zone,
    epoch     => $time,
  )->format_cldr("yyyy-MM-dd HH:mm zzz");

  if ($time <= time) {
    $event->reply("That sounded like you want to chill until the past ($when).");
    return;
  }

  $sy_timer->chilltill($time);
  $self->save_state;
  $event->reply("Okay, no more nagging until $when");
}

sub _handle_triple_zed ($self, $event, $text) {
  $self->_handle_chill($event, "");
}

sub _handle_commit ($self, $event, $comment) {
  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  if ($event->text =~ /\A\s*that\s*\z/) {
    my $last  = $self->get_last_utterance($event->source_identifier);

    unless (length $last) {
      return $event->reply("I don't know what 'that' refers to.");
    }

    $comment = $last;
  }

  my %meta;
  while ($comment =~ s/(?:\A|\s+)(DONE|STOP|CHILL)\z//) {
    $meta{$1}++;
  }

  $meta{DONE} = 1 if $comment =~ /\Adone\z/i;
  $meta{STOP} = 1 if $meta{DONE} or $meta{CHILL};

  my $lp_timer = $self->lp_timer_for_user($user);

  return $event->reply("You don't seem to have a running timer.")
    unless $lp_timer && ref $lp_timer; # XXX <-- stupid return type

  my $sy_timer = $self->timer_for_user($user);
  return $event->reply("You don't timer-capable.") unless $sy_timer;

  my $task_id = $lp_timer->{item_id};

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

  my $commit_res = $lpc->track_time({
    task_id => $task_id,
    work    => $lp_timer->{running_time},
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
  );

  if (@errors) {
    $also .= ".  I had trouble, though:  "
          .  join q{ and }, @errors;
  }

  my $time = concise( duration( $lp_timer->{running_time} * 3600 ) );

  my $uri= $self->item_uri($lp_timer->{item_id});

  my $task_res = $lpc->get_item($task_id);
  unless ($task_res->is_success) {
    return $event->reply(
      "I logged that time, but something went wrong trying to describe it!"
      . (@errors ? ("  I had other trouble, too: " . join q{ and }, @errors)
                 : q{}),
    );
  }

  my $task = $task_res->payload;

  my $base  = "Okay, I've committed $time of work$also.  The task was:";
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

sub _handle_abort ($self, $event, $text) {
  return $event->reply("I didn't understand your abort request.")
    unless $text =~ /^timer\b/i;

  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $event->reply("You don't have a running timer to abort.")
    unless my $timer = $timer_res->payload;

  my $stop_res = $lpc->stop_timer_for_task_id($timer->{item_id});
  my $clr_res  = $lpc->clear_timer_for_task_id($timer->{item_id});

  my $task_was = '';

  my $task_res = $lpc->get_item($timer->{item_id});

  if ($task_res->is_success) {
    my $uri = $self->item_uri($timer->{item_id});
    $task_was = " The task was: " . $task_res->payload->{name} . " ($uri)";
  }

  if ($stop_res->is_success and $clr_res->is_success) {
    $self->timer_for_user($user)->clear_last_nag;
    $event->reply("Okay, I stopped and cleared your timer.$task_was");
  } else {
    $event->reply("Something went wrong aborting your timer.");
  }
}

sub _handle_start ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  if ($text =~ m{\A\s*\*(\w+)\s*\z}) {
    my ($task, $error) = $self->task_for_shortcut($1);
    return $event->reply($error) unless $task;

    return $self->_handle_start_existing($event, $task);
  }

  if ($text =~ /\A[0-9]+\z/) {
    my $task_id = $text;
    my $task_res = $lpc->get_item($task_id);

    return $event->reply("Sorry, something went wrong trying to find that task.")
      unless $task_res->is_success;

    return $event->reply("Sorry, I couldn't find that task.")
      if $task_res->is_nil;

    return $self->_handle_start_existing($event, $task_res->payload);
  }

  if ($text eq 'next') {
    my $lp_tasks = $self->lp_tasks_for_user($user, 1);

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

  return $event->reply(q{You can either say "start LP-TASK-ID" or "start next".});
}

sub _handle_start_existing ($self, $event, $task) {
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

sub _handle_resume ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  my $lp_timer = $self->lp_timer_for_user($user);

  if ($lp_timer && ref $lp_timer) {
    my $task_res = $lpc->get_item($lp_timer->{item_id});

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

sub _handle_stop ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  return $event->reply("Quit it!  I'm telling mom!")
    if $text =~ /\Ahitting yourself[.!]*\z/;

  return $event->reply("I didn't understand your stop request.")
    unless $text eq 'timer';

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $event->reply("You don't have a running timer to stop.")
    unless my $timer = $timer_res->payload;

  my $stop_res = $lpc->stop_timer_for_task_id($timer->{item_id});
  return $event->reply("I couldn't stop your timer.")
    unless $stop_res->is_success;

  my $task_was = '';

  my $task_res = $lpc->get_item($timer->{item_id});

  if ($task_res->is_success) {
    my $uri = $self->item_uri($timer->{item_id});
    $task_was = " The task was: " . $task_res->payload->{name} . " ($uri)";

  }

  $self->timer_for_user($user)->clear_last_nag;
  return $event->reply("Okay, I stopped your timer.$task_was");
}

sub _handle_done ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $next;
  my $chill;
  if ($text) {
    my @things = split /\s*,\s*/, $text;
    for (@things) {
      if ($_ eq 'next')  { $next  = 1; next }
      if ($_ eq 'chill') { $chill = 1; next }

      return -1;
    }

    return $event->reply("No, it's nonsense to chill /and/ start a new task!")
      if $chill && $next;
  }

  $self->_handle_commit($event, 'DONE');
  $self->_handle_start($event, 'next') if $next;
  $self->_handle_chill($event, "until I'm back") if $chill;
  return;
}

sub _handle_reset ($self, $event, $text) {
  my $user = $event->from_user;
  return $event->reply($ERR_NO_LP) unless $self->auth_header_for($user);

  my $lpc = $self->lp_client_for_user($user);

  return $event->reply("I didn't understand your reset request. (try 'reset timer')")
    unless ($text // 'timer') eq 'timer';

  my $timer_res = $lpc->my_running_timer;

  return $event->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $event->reply("You don't have a running timer to reset.")
    unless my $timer = $timer_res->payload;

  my $task_id = $timer->{item_id};
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

sub _handle_spent ($self, $event, $text) {
  my $user = $event->from_user;

  return $event->reply($ERR_NO_LP)
    unless $user && $self->auth_header_for($user);

  my ($dur_str, $name) = $text =~ /\A(\V+?)(?:\s*:|\s*\son)\s+(\S.+)\z/s;
  unless ($dur_str && $name) {
    return $event->reply("Does not compute.  Usage:  spent DURATION on DESC-or-ID-or-URL");
  }

  my $duration;
  my $ok = eval { $duration = parse_duration($dur_str); 1 };
  unless ($ok) {
    return $event->reply("I didn't understand how long you spent!");
  }

  if ($duration > 12 * 86_400) {
    my $dur_restr = duration($duration);
    return $event->reply(
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

  if ($name =~ m{\A\s*\*(\w+)\s*\z}) {
    my ($task, $error) = $self->task_for_shortcut($1);
    return $event->reply($error) unless $task;

    return $self->_spent_on_existing($event, $task->{id}, $duration);
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

  $self->_execute_task_plan($event, $plan, $error);
}

sub _spent_on_existing ($self, $event, $task_id, $duration) {
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
  my $slack_base = sprintf qq{I logged that time on %s},
    $self->_slack_item_link_with_name($task);

  # if ($flags->{start} && $self->_start_timer($user, $task)) {
  #   $plain_base .= " and started your timer";
  #   $slack_base .= " and started your timer";
  # } else {
  #   $plain_base .= ", but I couldn't start your timer";
  #   $slack_base .= ", but I couldn't start your timer";
  # }

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
    return $event->reply("Sorry, I can only make todo items for you");
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

sub damage_report ($self, $event) {
  $event->text =~ /\A
    \s*
    ( damage \s+ )?
    report
    ( \s+ for \s+ (?<who> [a-z]+ ) )
    \s*
  \z/nix;
  my $who_name = $+{who} // $event->from_user->username;

  my $target = $self->resolve_name($who_name, $event->from_user);

  $event->mark_handled;

  return $event->reply("Sorry, I don't know who $who_name is, at least in LiquidPlanner.")
    unless $target && $self->auth_header_for($target);

  my $lp_id = $target->lp_id;

  my @to_check = (
    [ inbox  => "📫" => $self->inbox_package_id   ],
    [ urgent => "🔥" => $self->urgent_package_id  ],
  );

  if ($event->is_public) {
    $event->reply(
      "I'm generating that report now, and I'll send it to you privately in just a moment.",
      { slack_reaction => { event => $event, reaction => 'hourglass_flowing_sand' } },
    );
  } else {
    $event->reply(
      "I'm generating that report now, it'll be just a moment",
      { slack_reaction => { event => $event, reaction => 'hourglass_flowing_sand' } },
    );
  }

  my @summaries = ("Damage report for $who_name:");

  CHK: for my $check (@to_check) {
    my ($label, $icon, $package_id) = @$check;

    my $check_res = $self->lp_client_for_master->query_items({
      in    => $package_id,
      flags => {
        depth => -1,
        flat  => 1,
      },
      filters => [
        [ is_done   => 'is',  'false' ],
        [ owner_id  => '=',   $lp_id  ],
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

    for my $item ($check_res->payload_list) {
      next unless $item->{type} eq 'Task'; # Whatever. -- rjbs, 2018-06-15
      my ($assign) = grep {; $_->{person_id} == $lp_id }
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
      concise(duration($avg_age));

    $summary .= sprintf ", %u unestimated", $unest if $unest;

    push @summaries, $summary;
  }

  # XXX Needs reworking when we have current-iteration tracking.
  # -- rjbs, 2018-06-15
  my $pkg_summary   = $self->_build_package_summary(-1, $target);
  my $slack_summary = join qq{\n},
                      @summaries,
                      $self->_slack_pkg_summary($pkg_summary, $target->lp_id);

  my $reply = join qq{\n}, @summaries;

  $event->private_reply(
    "Report sent!",
    { slack_reaction => { event => $event, reaction => '-hourglass_flowing_sand' } },
  );

  my $method = $event->is_public ? 'private_reply' : 'reply';
  return $event->$method(
    $reply,
    {
      slack => $slack_summary,
    },
  );
}

sub reload_shortcuts ($self, $event) {
  $self->_set_projects($self->get_project_shortcuts);
  $self->_set_tasks($self->get_task_shortcuts);
  $event->reply("Shortcuts reloaded.");
  $event->mark_handled;
}

sub _build_package_summary ($self, $package_id, $user) {
  # This is hard-coded because all the iteration-handling code is buried in
  # LP-Tools, and merging that with Synergy without making a big pain right now
  # is... it's not happening this Friday afternoon. -- rjbs, 2018-06-15
  $package_id = 46281988;

  my $items_res = $self->lp_client_for_master->query_items({
    in    => $package_id,
    flags => { depth => -1 },
  });

  unless ($items_res->is_success) {
    $Logger->log("error getting tree for package $package_id");
    return;
  }

  my $summary = summarize_iteration($items_res->payload, $user->lp_id);
}

sub _slack_pkg_summary ($self, $summary, $lp_member_id) {
  my $text = "*—[ $summary->{name} ]—*\n";

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
      ($c->{type} eq 'Package' ? "\N{PACKAGE}" : "\N{FILE FOLDER}"),

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

  chomp $text;
  return $text;
}

sub summarize_iteration ($item, $member_id) {
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

      summarize_container($c, $summary, $member_id);

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

sub summarize_container ($item, $summary, $member_id) {
  CHILD: for my $c (@{ $item->{children} // []}) {
    if ($c->{type} eq 'Task') {
      my ($assign) = grep {; $_->{person_id} == $member_id }
                     $c->{assignments}->@*;

      next CHILD unless $assign;

      $summary->{total_tasks}++;
      $summary->{done_tasks}++ if $assign->{is_done};
      next CHILD;
    }

    summarize_container($c, $summary, $member_id);
  }

  return;
}

__PACKAGE__->add_preference(
  name      => 'api-token',
  validator => sub ($value) { return $value },
  describer => sub ($value) { return defined $value ? "<redacted>" : '<undef>' },
  default   => undef,
);

__PACKAGE__->add_preference(
  name      => 'should-nag',
  validator => sub ($value) { return bool_from_text($value) },
  default   => 0,
);

# Temporary, presumably. We're assuming here that the values from git are
# valid.
sub load_preferences_from_user ($self, $username) {
  $Logger->log([ "Loading LiquidPlanner preferences for %s", $username ]);
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
    my $item_res = $lpc->get_item($lp_timer->{item_id});
    if ($item_res->is_success) {
      $reply .= sprintf "LiquidPlanner timer running for %s on LP %s: %s",
        concise(duration($lp_timer->{running_time} * 3600)),
        $lp_timer->{item_id},
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
  # TODO: handle $rest being #project -- rjbs, 2018-07-12
  my $lpc = $self->lp_client_for_user($event->from_user);

  my $item_res = $lpc->get_item($rest);

  return $self->reply("I can't find an item with that id!")
    unless my $item = $item_res->payload;

  my $res = $lpc->query_items({
    in    => $rest,
    flags => {
      depth => 1,
    },
    filters => [
      [ is_done => 'is', 'false' ],
    ],
  });

  $event->mark_handled;

  return $event->reply("Sorry, I couldn't get the contents.")
    unless $res->is_success;

  $Logger->log([ "contents retrieved: %s", $res->payload ]);

  my @items = grep {; $_->{id} != $rest } $res->payload_list;
  $#items = 9 if @items > 10; # TODO: add pagination -- rjbs, 2018-07-12

  my $pkg_summary = {
    name       => $item->{name},
    containers => [ grep {; $_->{type} =~ /\A Project | Package \z/x } @items ],
    tasks      => [ grep {; $_->{type} eq 'Task' } @items ],
    events     => [ grep {; $_->{type} eq 'Event' } @items ],
    others     => [ grep {; $_->{type} !~ /\A Project | Package | Task | Event \z/x } @items ],
  };

  my $slack_summary = $self->_slack_pkg_summary($pkg_summary, -1);

  my $method = $event->is_public ? 'private_reply' : 'reply';
  return $event->$method(
    "(this is only useful on Slack for now)",
    {
      slack => $slack_summary,
    },
  );
}

1;
