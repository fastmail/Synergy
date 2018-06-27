use v5.24.0;
package Synergy::Reactor::LiquidPlanner;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use Lingua::EN::Inflect qw(PL_N);
use List::Util qw(first uniq);
use Net::Async::HTTP;
use JSON 2 ();
use Time::Duration;
use Time::Duration::Parse;
use Synergy::Logger '$Logger';
use Synergy::LPC; # LiquidPlanner Client, of course
use Synergy::Timer;
use Synergy::Util qw(parse_time_hunk pick_one);
use DateTime;
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

my $ERR_NO_LP = "You don't seem to be a LiquidPlanner-enabled user.";

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
}

sub _link_base_uri ($self) {
  return sprintf "https://app.liquidplanner.com/space/%s/projects/panel/",
    $self->workspace_id;
}

sub item_uri ($self, $task_id) {
  return $self->_link_base_uri . $task_id;
}

sub _slack_item_link ($self, $item) {
  sprintf "<%s|LP>\N{THIN SPACE}%s",
    $self->item_uri($item->{id}),
    $item->{id};
}

my $CONFIG;  # XXX use real config

$CONFIG = {
  liquidplanner => {
    workspace => '14822',
    package => {
      inbox => '6268529',
      urgent => '11388082',
      recurring => '27659967',
    },
    project => {
      comms =>  '39452359',
      cyrus =>  '38805977',
      fastmail =>  '36611517',
      listbox =>  '274080',
      plumbing =>  '39452373',
      pobox =>  '274077',
      topicbox =>  '27495364',
    },
  },
};

my %KNOWN = (
  last      => \&_handle_last,
  timer     => \&_handle_timer,
  task      => \&_handle_task,
  tasks     => \&_handle_tasks,
  inbox     => \&_handle_inbox,
  urgent    => \&_handle_urgent,
  recurring => \&_handle_recurring,
  '++'      => \&_handle_plus_plus,
  '>>'      => \&_handle_angle_angle,
  good      => \&_handle_good,
  gruß      => \&_handle_good,
  expand    => \&_handle_expand,
  chill     => \&_handle_chill,
  zzz       => \&_handle_triple_zed,
  shows     => \&_handle_shows,
  "show's"  => \&_handle_shows,
  showtime  => \&_handle_showtime,
  commit    => \&_handle_commit,
  abort     => \&_handle_abort,
  start     => \&_handle_start,
  stop      => \&_handle_stop,
  resume    => \&_handle_resume,
  restart   => \&_handle_resume,
  reset     => \&_handle_reset,
  done      => \&_handle_done,
  spent     => \&_handle_spent,
  projects  => \&_handle_projects,
  todo      => \&_handle_todo,
  todos     => \&_handle_todos,
);

sub listener_specs {
  return (
    {
      name      => "you're-back",
      method    => 'see_if_back',
      predicate => sub { 1 },
    },
    {
      name      => "liquid planner",
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
      }
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

sub dispatch_event ($self, $event, $rch) {
  unless ($event->from_user) {
    $rch->reply("Sorry, I don't know who you are.");
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

  # It's not handled yet, but it will have been by the time we return!
  $event->mark_handled;

  # we can be polite even to non-lp-enabled users
  return $self->_handle_good($event, $rch, $rest) if $what eq 'good';

  unless ($event->from_user->lp_auth_header) {
    $rch->reply($ERR_NO_LP);
    return 1;
  }

  return $KNOWN{$what}->($self, $event, $rch, $rest)
}

sub provide_lp_link ($self, $event, $rch) {
  my $user = $event->from_user;
  return unless $user && $user->lp_auth_header;

  state $lp_id_re = qr/\bLP([1-9][0-9]{5,10})\b/;

  if (my ($item_id) = $event->text =~ $lp_id_re) {
    my $item_res = $self->lp_client_for_user($user)->get_item($item_id);

    unless ($item_res->is_success) {
      return $rch->reply("Sorry, something went wrong getting looking for LP$item_id");
    }

    return $rch->reply("I can't find anything for LP$item_id.")
      unless my $item = $item_res->payload;

    my $name = $item->{name};

    my $reply;

    if ($item->{type} =~ /\A Task | Package | Project \z/x) {
      my $icon = $item->{type} eq 'Task'    ? ($item->{is_done} ? "✓" : "•")
               : $item->{type} eq 'Package' ? "📦"
               : $item->{type} eq 'Project' ? "📁"
               :                              "($item->{type})";

      my $uri = $self->item_uri($item_id);

      $rch->reply(
        "$icon LP$item_id: $item->{name} ($uri)",
        {
          slack => sprintf '%s %s: %s',
            $icon, $self->_slack_item_link($item), $item->{name},
        },
      );
    } else {
      $rch->reply("LP$item_id: is a $item->{type}");
    }

    if ($event->was_targeted && $event->text =~ /\A\s* $lp_id_re \s*\z/x) {
      # do better than bort
      $event->mark_handled;
    }
  }
}

has _last_lp_timer_ids => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

sub last_lp_timer_id_for_user ($self, $user) {
  return $self->_last_lp_timer_ids->{ $user->username };
}

sub set_last_lp_timer_id_for_user ($self, $user, $timer_id) {
  $self->_last_lp_timer_ids->{ $user->username } = $timer_id;
}

sub last_lp_timer_for_user ($self, $user) {
  return unless $user->lp_auth_header;
  return unless my $lp_timer_id = $self->last_lp_timer_id_for_user($user);

  my $timers_res = $self->lp_client_for_user($user)->my_timers;

  return unless $timers_res->is_success;

  my ($timer) = grep {; $_->{id} eq $lp_timer_id } $timers_res->payload_list;

  return $timer;
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

  return {
    user_timers => {
      map {; $_ => $timers->{$_}->as_hash }
        keys $self->user_timers->%*
    },
  };
}

sub timer_for_user ($self, $user) {
  return unless $user->has_lp_token;

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

sub record_utterance ($self, $event, $rch) {
  # We're not going to support "++ that" by people who are not users.
  return unless $event->from_user;

  if ($event->text =~ /^last$/i) {
    return;
  }

  $self->set_last_utterance($event->source_identifier, $event->text);

  return;
}

sub see_if_back ($self, $event, $rch) {
  # We're not going to support "++ that" by people who are not users.
  return unless $event->from_user;

  my $timer = $self->timer_for_user($event->from_user) || return;

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
    $rch->reply("You're back!  No longer chilling.")
      if $timer->is_business_hours;
  }
}

has projects => (
  isa => 'HashRef',
  traits => [ 'Hash' ],
  handles => {
    projects            => 'keys',
    project_by_shortcut => 'get',
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
    tasks             => 'keys',
    task_by_shortcut  => 'get',
  },
  lazy => 1,
  default => sub ($self) {
    $self->get_task_shortcuts;
  },
  writer    => '_set_tasks',
);

sub start ($self) {
  if (my $state = $self->fetch_state) {
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

    $self->save_state;
  }

  my $timer = IO::Async::Timer::Periodic->new(
    interval => 300,
    on_tick  => sub ($timer, @arg) { $self->nag($timer); },
  );

  $self->hub->loop->add($timer);

  $timer->start;
}

sub nag ($self, $timer, @) {
  $Logger->log("considering nagging");

  USER: for my $user ($self->hub->user_directory->users) {
    next USER unless my $sy_timer = $self->timer_for_user($user);

    next USER unless $user->should_nag;

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

    if ($sy_timer->is_showtime) {
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

  for my $item ($res->payload_list) {
    # Impossible, right?
    next unless my $shortcut = $item->{custom_field_values}{"Synergy $type Shortcut"};

    # We'll deal with conflicts later. -- rjbs, 2018-01-22
    $dict{ lc $shortcut } //= [];

    # But don't add the same project twice. -- michael, 2018-04-24
    my @existing = grep {; $_->{id} eq $item->{id} } $dict{ lc $shortcut }->@*;
    if (@existing) {
      $Logger->log([ "Duplicate \l$type found; got %s, conflicts with %s",
        $item,
        \@existing
      ]);
      next;
    }

    push $dict{ lc $shortcut }->@*, {
      id        => $item->{id},
      shortcut  => $shortcut,
      name      => $item->{name},
    };
  }

  return \%dict;
}

sub get_project_shortcuts ($self) { $self->_get_treeitem_shortcuts('Project') }
sub get_task_shortcuts    ($self) { $self->_get_treeitem_shortcuts('Task') }

sub lp_client_for_user ($self, $user) {
  Synergy::LPC->new({
    auth_token    => $user->lp_auth_header,
    workspace_id  => $self->workspace_id,
    logger_callback   => sub { $Logger },
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

sub http_get_for_user ($self, $user, $path, @arg) {
  return $self->hub->http_get(
    $self->_lp_base_uri . $path,
    @arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_post_for_user ($self, $user, $path, @arg) {
  return $self->hub->http_post(
    $self->_lp_base_uri . $path,
    @arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_get_for_master ($self, $path, @arg) {
  my ($master) = $self->hub->user_directory->master_users;
  unless ($master) {
    $Logger->log("No master users configured");
    return;
  }

  $self->http_get_for_user($master, $path, @arg);
}

sub _handle_last ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  return if length $text;

  $event->mark_handled;

  if (my $last = $self->get_last_utterance(
    $event->source_identifier
  )) {
    $rch->reply("The last thing you said here was: $last");
  } else {
    $rch->reply("You haven't said anything here yet that I've seen (ignoring 'last')");
  }
}

sub _handle_timer ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $rch->reply("Sorry, something went wrong getting your timer.")
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

    return $rch->reply($msg);
  }

  my $time = concise( duration( $timer->{running_time} * 3600 ) );

  my $task_res = $lpc->get_item($timer->{item_id});

  my $task = ($task_res->is_success && $task_res->payload)
          || { id => $timer->{item_id}, name => '??' };

  my $url = $self->item_uri($task->{id});

  my $base  = "Your timer has been running for $time, work on";
  my $slack = sprintf '%s: %s %s %s',
    $base, $url, $self->_slack_item_link($task), $task->{name};

  return $rch->reply(
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
  my $projects = $self->project_by_shortcut(lc $project_name);

  unless ($projects && @$projects) {
    $error->{project} = qq{I don't know any LiquidPlanner project with the}
                      . qq{ shortcut "$project_name".};

    return;
  }

  if (@$projects > 1) {
    $error->{project}
      = qq{More than one LiquidPlanner project has the shortcut "$project_name". }
      . qq{Their ids are: }
      . join(q{, }, map {; $_->{id} } @$projects);

    return;
  }

  $plan->{project_id} = $projects->[0]{id};
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
  my $via = $event->from_channel->describe_event($event);
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

sub _handle_task ($self, $event, $rch, $text) {
  # because of "new task for...";
  my $what = $text =~ s/\Atask\s+//r;

  if ($text =~ /\A \s* shortcuts \s* \z/xi) {
    return $self->_handle_task_shortcuts($event, $rch, $text);
  }

  my ($target, $spec_text) = $what =~ /\s*for\s+@?(.+?)\s*:\s+((?s:.+))\z/;

  unless ($target and $spec_text) {
    return $rch->reply("Does not compute.  Usage:  task for TARGET: TASK");
  }

  my @target_names = split /(?:\s*,\s*|\s+and\s+)/, $target;

  my ($plan, $error) = $self->task_plan_from_spec(
    $event,
    {
      usernames => [ @target_names ],
      text      => $spec_text,
    },
  );

  $self->_execute_task_plan($event, $rch, $plan, $error);
}

sub _execute_task_plan ($self, $event, $rch, $plan, $error) {
  if ($error) {
    my $errors = join q{  }, values %$error;
    return $rch->reply($errors);
  }

  my $lpc = $self->lp_client_for_user($event->from_user);

  my $arg = {};

  my $task = $self->_create_lp_task($rch, $plan, $arg);

  unless ($task) {
    if ($arg->{already_notified}) {
      return;
    } else {
      return $rch->reply(
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
      $self->set_last_lp_timer_id_for_user(
        $event->from_user,
        $res->payload->{id}
      );

      $reply_base .= q{, timer started};
    } else {
      $reply_base .= q{, but the timer couldn't be started};
    }
  }

  if (my $log_hrs = $plan->{log_hours}) {
    my $track_ok = $lpc->track_time({
      task => $task,
      work => $log_hrs,
      done => $plan->{done},
      member_id => $event->from_user->lp_id,
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
      task => $task,
      work => 0,
      done => $plan->{done},
      member_id => $event->from_user->lp_id,
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

  $rch->reply($plain, { slack => $slack });
}

sub _start_timer ($self, $user, $task) {
  my $res = $self->lp_client_for_user($user)
                 ->start_timer_for_task_id($task->{id});

  return unless $res->is_success;

  # What does this mean?  Copied and pasted. -- rjbs, 2018-06-16
  return unless $res->payload->{start};

  $self->set_last_lp_timer_id_for_user($user, $res->payload->{id});
  return 1;
}

sub lp_tasks_for_user ($self, $user, $count, $which='tasks', $arg = {}) {
  my $lpc = $self->lp_client_for_user($user);

  my $res = $lpc->upcoming_tasks_for_member_id($user->lp_id);

  return unless $res->is_success;

  my @tasks = grep {; $_->{type} eq 'Task' } $res->payload_list;

  if ($which eq 'tasks') {
    @tasks = grep {;
      (! grep { $CONFIG->{liquidplanner}{package}{inbox} == $_ } $_->{parent_ids}->@*)
      &&
      (! grep { $CONFIG->{liquidplanner}{package}{inbox} == $_ } $_->{package_ids}->@*)
    } @tasks;
  } else {
    my $package_id = $CONFIG->{liquidplanner}{package}{ $which };
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
    my $urgent = $CONFIG->{liquidplanner}{package}{urgent};
    for (@tasks) {
      $_->{name} = "[URGENT] $_->{name}"
        if (grep { $urgent == $_ } $_->{parent_ids}->@*)
        || (grep { $urgent == $_ } $_->{package_ids}->@*);
    }
  }

  return \@tasks;
}

sub _send_task_list ($self, $event, $rch, $tasks) {
  my $reply = q{};
  my $slack = q{};

  for my $task (@$tasks) {
    my $uri = $self->item_uri($task->{id});
    $reply .= "$task->{name} ($uri)\n";
    $slack .= $self->_slack_item_link($task) . " $task->{name}\n";
  }

  chomp $reply;
  chomp $slack;

  $rch->private_reply($reply, { slack => $slack });
}

sub _handle_tasks ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my ($how_many) = $text =~ /\Atasks\s+([0-9]+)\z/;

  my $per_page = 5;
  my $page = $how_many && $how_many > 0 ? $how_many : 1;

  unless ($page <= 10) {
    return $rch->reply(
      "If it's not in your first ten pages, better go to the web.",
    );
  }

  my $count = $per_page * $page;
  my $start = $per_page * ($page - 1);

  my $lp_tasks = $self->lp_tasks_for_user($user, $count, 'tasks');
  my @task_page = splice @$lp_tasks, $start, $per_page;

  return $rch->reply("You don't have any open tasks right now.  Woah!")
    unless @task_page;

  $self->_send_task_list($event, $rch, \@task_page);

  $rch->reply("Responses to <tasks> are sent privately.") if $event->is_public;
}

sub _handle_task_like ($self, $event, $rch, $cmd, $count) {
  my $user = $event->from_user;

  my $arg = $cmd eq 'urgent' ? { no_prefix => 1 } : {};
  my $lp_tasks = $self->lp_tasks_for_user($user, $count, $cmd, $arg);

  unless (@$lp_tasks) {
    my $suffix = $cmd =~ /(inbox|urgent)/n
               ? ' \o/'
               : '';
    $rch->reply("You don't have any open $cmd tasks right now.$suffix");
    return;
  }

  $self->_send_task_list($event, $rch, $lp_tasks);
  $rch->reply("Responses to <$cmd> are sent privately.") if $event->is_public;
}

sub _handle_inbox ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'inbox', 200);
}

sub _handle_urgent ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'urgent', 100);
}

sub _handle_recurring ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'recurring', 100);
}

sub _handle_plus_plus ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  unless (length $text) {
    return $rch->reply("Thanks, but I'm only as awesome as my creators.");
  }

  my $who     = $event->from_user->username;
  my $pretend = "task for $who: $text";

  if ($text =~ /\A\s*that\s*\z/) {
    my $last  = $self->get_last_utterance($event->source_identifier);

    unless (length $last) {
      return $rch->reply("I don't know what 'that' refers to.");
    }

    $pretend = "task for $who: $last";
  }

  return $self->_handle_task($event, $rch, $pretend);
}

sub _handle_angle_angle ($self, $event, $rch, $text) {
  my ($target, $rest) = split /\s+/, $text, 2;

  $target =~ s/:$//;

  my $pretend = "task for $target: $rest";

  return $self->_handle_task($event, $rch, $pretend);
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

sub _handle_good ($self, $event, $rch, $text) {
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

  return $rch->reply($reply) if $reply and not $user->lp_auth_header;

  # TODO: implement expandos
  if ($expand && $user->tasks_for_expando($expand)) {
    $self->expand_tasks($rch, $event, $expand, "$reply  ");
    $reply = '';
  }

  if ($stop) {
    my $timer_res = $self->lp_client_for_user($user)->my_running_timer;
    return $rch->reply("I couldn't figure out whether you had a running timer, so I gave up.")
      if $timer_res->is_failure;

    return $rch->reply("You've got a running timer!  You should commit it.")
      if $timer_res->has_payload;
  }

  if ($end_of_day && (my $sy_timer = $self->timer_for_user($user))) {
    my $time = parse_time_hunk('until tomorrow', $user);
    $sy_timer->chilltill($time);
    $self->save_state;
  }

  return $rch->reply($reply) if $reply;
}

sub _handle_expand ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my ($what) = $text =~ /^([a-z_]+)/i;
  $self->expand_tasks($rch, $event, $what);
}

sub expand_tasks ($self, $rch, $event, $expand_target, $prefix='') {
  my $user = $event->from_user;

  unless ($expand_target && $expand_target =~ /\S/) {
    my @names = sort $user->defined_expandoes;
    return $rch->reply($prefix . "You don't have any expandoes") unless @names;
    return $rch->reply($prefix . "Your expandoes: " . (join q{, }, @names));
  }

  my @tasks = $user->tasks_for_expando($expand_target);
  return $rch->reply($prefix . "You don't have an expando for <$expand_target>")
    unless @tasks;

  my $parent = $CONFIG->{liquidplanner}{package}{recurring};
  my $desc = $rch->channel->describe_event($event);

  my (@ok, @fail);
  for my $task (@tasks) {
    my $payload = { task => {
      name        => $task,
      parent_id   => $parent,
      assignments => [ { person_id => $user->lp_id } ],
      description => $desc,
    } };

    $Logger->log([ "creating LP task: %s", $payload ]);

    my $res = $self->http_post_for_user($user,
      "/tasks",
      Content_Type => 'application/json',
      Content => $JSON->encode($payload),
    );
    if ($res->is_success) {
      push @ok, $task;
    } else {
      $Logger->log([ "error creating LP task: %s", $res->decoded_content ]);
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
  $rch->reply($prefix . $reply);
}

sub _create_lp_task ($self, $rch, $my_arg, $arg) {
  my %container = (
    package_id  => $my_arg->{urgent}
                ? $CONFIG->{liquidplanner}{package}{urgent}
                : $CONFIG->{liquidplanner}{package}{inbox},
    parent_id   => $my_arg->{project_id}
                ?  $my_arg->{project_id}
                :  undef,
  );

  if ($my_arg->{name} =~ s/#(.*)$//) {
    my $project = lc $1;

    my $projects = $self->project_by_shortcut($project);

    unless ($projects && @$projects) {
      $arg->{already_notified} = 1;

      return $rch->reply(
          "I am not aware of a project named '$project'. (Try 'projects' "
        . "to see what projects I know about.)",
      );
    }

    if (@$projects > 1) {
      return $rch->reply(
          "More than one LiquidPlanner project has the shortcut '$project'. "
        . "Their ids are: "
        . join(q{, }, map {; $_->{id} } @$projects),
      );
    }

    $container{parent_id} = $projects->[0]{id};
  }

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

  my $payload = { task => {
    name        => $my_arg->{name},
    assignments => [ map {; assignment($_) } @{ $my_arg->{owners} } ],
    description => $my_arg->{description},

    %container,
  } };

  my $as_user = $my_arg->{user} // $self->master_lp_user;

  my $res = $self->http_post_for_user(
    $as_user,
    "/tasks",
    Content_Type => 'application/json',
    Content => $JSON->encode($payload),
  );

  unless ($res->is_success) {
    $Logger->log("error creating task: " . $res->as_string);
    return;
  }

  my $task = $JSON->decode($res->decoded_content);

  return $task;
}

sub lp_timer_for_user ($self, $user) {
  return unless $user->lp_auth_header;

  my $timer_res = $self->lp_client_for_user($user)->my_running_timer;

  return unless $timer_res->is_success;

  my $timer = $timer_res->payload;

  if ($timer) {
    $self->set_last_lp_timer_id_for_user($user, $timer->{id});
  }

  return $timer;
}

sub _handle_showtime ($self, $event, $rch, $text) {
  my $user  = $event->from_user;
  my $timer = $user
            ? $self->timer_for_user($user)
            : undef;

  return $rch->reply($ERR_NO_LP)
    unless $timer;

  if ($timer->has_chilltill and $timer->chilltill > time) {
    if ($timer->is_business_hours) {
      $rch->reply("Okay, back to work!");
    } else {
      $rch->reply("Back to normal business hours, then.");
    }
  } elsif ($timer->is_business_hours) {
    $rch->reply("I thought it was already showtime!");
  } else {
    $timer->start_showtime;
    return $rch->reply("Okay, business hours extended!");
  }

  $timer->clear_chilltill;
  $self->save_state;
  return;
}

sub _handle_shows ($self, $event, $rch, $text) {
  return $self->_handle_chill($event, $rch, 'until tomorrow')
    if $text =~ /\s*over\s*[+!.]*\s*/i;

  return;
}

sub _handle_chill ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  {
    my $timer_res = $self->lp_client_for_user($user)->my_running_timer;

    return $rch->reply("You've got a running timer!  You should commit it.")
      if $timer_res->is_success && $timer_res->has_payload;
  }

  my $sy_timer = $self->timer_for_user($user);

  $text =~ s/[.!?]+\z// if length $text;

  if (! length $text or $text =~ /^until\s+I'm\s+back\s*$/i) {
    $sy_timer->chill_until_active(1);
    $self->save_state;
    return $rch->reply("Okay, I'll stop pestering you until you've active again.");
  }

  my $time = parse_time_hunk($text, $user);
  return $rch->reply("Sorry, I couldn't parse '$text' into a time")
    unless $time;

  my $when = DateTime->from_epoch(
    time_zone => $user->time_zone,
    epoch     => $time,
  )->format_cldr("yyyy-MM-dd HH:mm zzz");

  if ($time <= time) {
    $rch->reply("That sounded like you want to chill until the past ($when).");
    return;
  }

  $sy_timer->chilltill($time);
  $self->save_state;
  $rch->reply("Okay, no more nagging until $when");
}

sub _handle_triple_zed ($self, $event, $rch, $text) {
  $self->_handle_chill($event, $rch, "");
}

sub _handle_commit ($self, $event, $rch, $comment) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $lpc = $self->lp_client_for_user($user);

  if ($event->text =~ /\A\s*that\s*\z/) {
    my $last  = $self->get_last_utterance($event->source_identifier);

    unless (length $last) {
      return $rch->reply("I don't know what 'that' refers to.");
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

  return $rch->reply("You don't seem to have a running timer.")
    unless $lp_timer && ref $lp_timer; # XXX <-- stupid return type

  my $sy_timer = $self->timer_for_user($user);
  return $rch->reply("You don't timer-capable.") unless $sy_timer;

  my $task_res = $self->http_get_for_user($user, "/tasks/$lp_timer->{item_id}");

  unless ($task_res->is_success) {
    return $rch->reply("I couldn't log the work because I couldn't find the current task's activity id.");
  }

  my $task = $JSON->decode($task_res->decoded_content);
  my $activity_id = $task->{activity_id};

  unless ($activity_id) {
    return $rch->reply("I couldn't log the work because the task doesn't have a defined activity.");
  }

  if ($meta{STOP} and ! $sy_timer->chilling) {
    if ($meta{CHILL}) {
      $sy_timer->chill_until_active(1);
    } else {
      # Don't complain 30s after we stop work!  Give us a couple minutes to
      # move on to the next task. -- rjbs, 2015-04-21
      $sy_timer->chilltill(time + 300);
    }
  }

  # get timer
  # get task
  # track_time
  # clear timer
  # maybe: stop timer

  my $task_base = "/tasks/$lp_timer->{item_id}";

  my $commit_res = $lpc->track_time({
    task  => $task,
    work  => $lp_timer->{running_time},
    done  => $meta{DONE},
    comment => $comment,
    member_id => $user->lp_id,
  });

  unless ($commit_res->is_success) {
    $self->save_state;
    return $rch->reply("I couldn't commit your work, sorry.");
  }

  $sy_timer->clear_last_nag;
  $self->save_state;

  {
    my $clear_res = $lpc->clear_timer_for_task_id($task->{id});
    $meta{CLEARFAIL} = ! $clear_res->is_success;
  }

  unless ($meta{STOP}) {
    my $start_res = $lpc->start_timer_for_task_id($task->{id});
    $meta{STARTFAIL} = ! $start_res->is_success;
  }

  my $also
    = $meta{DONE}  ? " and marked the task done"
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

  my $uri   = $self->item_uri($lp_timer->{item_id});
  my $base  = "Okay, I've committed $time of work$also.  The task was:";
  my $text  = "$base $task->{name} ($uri)";
  my $slack = sprintf '%s  %s %s',
    $base, $self->_slack_item_link($task), $task->{name};

  $rch->reply(
    $text,
    {
      slack => $slack,
    }
  );
}

sub _handle_abort ($self, $event, $rch, $text) {
  return $rch->reply("I didn't understand your abort request.")
    unless $text =~ /^timer\b/i;

  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $rch->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $rch->reply("You don't have a running timer to abort.")
    unless my $timer = $timer_res->payload;

  my $stop_res = $lpc->stop_timer_for_task_id($timer->{item_id});
  my $clr_res  = $lpc->clear_timer_for_task_id($timer->{item_id});

  if ($stop_res->is_success and $clr_res->is_success) {
    $self->timer_for_user($user)->clear_last_nag;
    $rch->reply("Okay, I stopped and cleared your timer.");
  } else {
    $rch->reply("Something went wrong aborting your timer.");
  }
}

sub _handle_start ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $lpc = $self->lp_client_for_user($user);

  if ($text =~ /\A[0-9]+\z/) {
    my $task_id = $text;

    # TODO: make sure the task isn't closed! -- rjbs, 2016-01-25
    # TODO: print the description of the task instead of its number -- rjbs,
    # 2016-01-25
    my $start_res = $lpc->start_timer_for_task_id($task_id);

    if ($start_res->is_success) {
      $self->set_last_lp_timer_id_for_user($user, $start_res->payload->{id});

      my $task_res = $lpc->get_item($task_id);
      my $task = ($task_res->is_success && $task_res->payload)
              || { id => $task_id, name => '??' };

      my $uri   = $self->item_uri($task_id);
      my $text  = "Started task: $task->{name} ($uri)";
      my $slack = sprintf "Started task %s: %s",
        $self->_slack_item_link($task), $task->{name};

      return $rch->reply(
        $text,
        { slack => $slack },
      );
    } else {
      return $rch->reply("I couldn't start the timer for $text.");
    }
  } elsif ($text eq 'next') {
    my $lp_tasks = $self->lp_tasks_for_user($user, 1);

    unless ($lp_tasks && $lp_tasks->[0]) {
      return $rch->reply("I can't get your tasks to start the next one.");
    }

    my $task = $lp_tasks->[0];
    my $start_res = $lpc->start_timer_for_task_id($task->{id});

    if ($start_res->is_success) {
      $self->set_last_lp_timer_id_for_user($user, $start_res->payload->{id});

      my $uri   = $self->item_uri($task->{id});
      my $text  = "Started task: $task->{name} ($uri)";
      my $slack = sprintf "Started task %s: %s",
        $self->_slack_item_link($task), $task->{name};

      return $rch->reply(
        $text,
        { slack => $slack },
      );
    } else {
      return $rch->reply("I couldn't start your next task.");
    }
  }

  return $rch->reply(q{You can either say "start LP-TASK-ID" or "start next".});
}

sub _handle_resume ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $lpc = $self->lp_client_for_user($user);

  my $lp_timer = $self->lp_timer_for_user($user);

  if ($lp_timer && ref $lp_timer) {
    my $task_res = $self->http_get_for_user($user, "/tasks/$lp_timer->{item_id}");

    unless ($task_res->is_success) {
      return $rch->reply("You already have a running timer (but I couldn't figure out its task...)");
    }

    my $task = $JSON->decode($task_res->decoded_content);
    return $rch->reply("You already have a running timer ($task->{name})");
  }

  my $last_lp_timer = $self->last_lp_timer_for_user($user);

  unless ($last_lp_timer) {
    return $rch->reply("I'm not aware of any previous timer you had running. Sorry!");
  }

  my $task_res = $self->http_get_for_user($user, "/tasks/$last_lp_timer->{item_id}");

  unless ($task_res->is_success) {
    return $rch->reply("I found your timer but I couldn't figure out its task...");
  }

  my $task = $JSON->decode($task_res->decoded_content);
  my $res  = $lpc->start_timer_for_task_id($task->{id});

  unless ($res->is_success) {
    return $rch->reply("I failed to resume the timer for $task->{name}, sorry!");
  }

  return $rch->reply("Timer resumed. Task is: $task->{name}");
}

sub _handle_stop ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  return $rch->reply("Quit it!  I'm telling mom!")
    if $text =~ /\Ahitting yourself[.!]*\z/;

  return $rch->reply("I didn't understand your stop request.")
    unless $text eq 'timer';

  my $lpc = $self->lp_client_for_user($user);
  my $timer_res = $lpc->my_running_timer;

  return $rch->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $rch->reply("You don't have a running timer to stop.")
    unless my $timer = $timer_res->payload;

  my $stop_res = $lpc->stop_timer_for_task_id($timer->{item_id});
  return $rch->reply("I couldn't stop your timer.")
    unless $stop_res->is_success;

  $self->timer_for_user($user)->clear_last_nag;
  return $rch->reply("Okay, I stopped your timer.");
}

sub _handle_done ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $next;
  my $chill;
  if ($text) {
    my @things = split /\s*,\s*/, $text;
    for (@things) {
      if ($_ eq 'next')  { $next  = 1; next }
      if ($_ eq 'chill') { $chill = 1; next }

      return -1;
    }

    return $rch->reply("No, it's nonsense to chill /and/ start a new task!")
      if $chill && $next;
  }

  $self->_handle_commit($event, $rch, 'DONE');
  $self->_handle_start($event, $rch, 'next') if $next;
  $self->_handle_chill($event, $rch, "until I'm back") if $chill;
  return;
}

sub _handle_reset ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  return $rch->reply($ERR_NO_LP) unless $user->lp_auth_header;

  my $lpc = $self->lp_client_for_user($user);

  return $rch->reply("I didn't understand your reset request. (try 'reset timer')")
    unless ($text // 'timer') eq 'timer';

  my $timer_res = $lpc->my_running_timer;

  return $rch->reply("Sorry, something went wrong getting your timer.")
    unless $timer_res->is_success;

  return $rch->reply("You don't have a running timer to reset.")
    unless my $timer = $timer_res->payload;

  my $task_id = $timer->{item_id};
  my $clr_res = $lpc->clear_timer_for_task_id($task_id);

  return $rch->reply("Something went wrong resetting your timer.")
    unless $clr_res->is_success;

  $self->timer_for_user($user)->clear_last_nag;

  my $start_res = $lpc->stop_timer_for_task_id($task_id);

  if ($start_res->is_success) {
    $self->set_last_lp_timer_id_for_user($user, $timer->{id});
    $rch->reply("Okay, I cleared your timer and left it running.");
  } else {
    $rch->reply("Okay, I cleared your timer but couldn't restart it... sorry!");
  }
}

sub _handle_spent ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my ($dur_str, $name) = $text =~ /\A(\V+?)(?:\s*:|\s*\son)\s+(\S.+)\z/s;
  unless ($dur_str && $name) {
    return $rch->reply("Does not compute.  Usage:  spent DURATION on DESC-or-ID-or-URL");
  }

  my $duration;
  my $ok = eval { $duration = parse_duration($dur_str); 1 };
  unless ($ok) {
    return $rch->reply("I didn't understand how long you spent!");
  }

  if ($duration > 12 * 86_400) {
    my $dur_restr = duration($duration);
    return $rch->reply(
        qq{You said to spend "$dur_str" which I read as $dur_restr.  }
      . qq{That's too long!},
    );
  }

  my $workspace_id = $self->workspace_id;

  if (
    $name =~ m{\A\s*(?:https://app.liquidplanner.com/space/$workspace_id/.*/)?([0-9]+)P?/?\s*\z}
  ) {
    my ($task_id) = ($1);
    return $self->_spent_on_existing($event, $rch, $task_id, $duration);
  }

  if ($name =~ m{\A\s*\*(\w+)\s*\z}) {
    my $task = $self->task_by_shortcut(lc $1);
    return $self->reply(qq{I don't know a task with the shortcut "$1".})
      unless $task;

    my $task_id = $task->[0]{id};
    return $self->_spent_on_existing($event, $rch, $task_id, $duration);
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

  $self->_execute_task_plan($event, $rch, $plan, $error);
}

sub _spent_on_existing ($self, $event, $rch, $task_id, $duration) {
  my $user = $event->from_user;
  my $task_res = $self->http_get_for_user($user, "/tasks/$task_id");

  my $lpc = $self->lp_client_for_user($user);

  unless ($task_res->is_success) {
    return $rch->reply("I couldn't log the work because I couldn't find the task.");
  }

  my $task = $JSON->decode($task_res->decoded_content);
  my $activity_id = $task->{activity_id};

  unless ($activity_id) {
    return $rch->reply("I couldn't log the work because the task doesn't have a defined activity!");
  }

  my $track_ok = $lpc->track_time({
    task => $task,
    work => $duration / 3600,
    member_id => $user->lp_id,
  });

  unless ($track_ok) {
    return $rch->reply("I couldn't log your time, sorry.");
  }

  my $uri = $self->item_uri($task->{id});

  my $plain_base = qq{I logged that time on "$task->{name}"};
  my $slack_base = sprintf qq{I logged that time on %s ("%s")},
    $self->_slack_item_link($task),
    $task->{name};

  # if ($flags->{start} && $self->_start_timer($user, $task)) {
  #   $plain_base .= " and started your timer";
  #   $slack_base .= " and started your timer";
  # } else {
  #   $plain_base .= ", but I couldn't start your timer";
  #   $slack_base .= ", but I couldn't start your timer";
  # }

  return $rch->reply(
    "$plain_base.\n$uri",
    {
      slack => "$slack_base.",
    }
  );
}

sub _handle_projects ($self, $event, $rch, $text) {
  my @sorted = sort $self->projects;

  $rch->reply("Responses to <projects> are sent privately.")
    if $event->is_public;
  $rch->private_reply('Known projects:');

  for my $project (@sorted) {
    my $id = $self->project_by_shortcut($project)->[0]->{id};   # cool, LP
    $rch->private_reply("$project (" . $self->item_uri($id) . ")");
  }
}

sub _handle_task_shortcuts ($self, $event, $rch, $text) {
  my @sorted = sort $self->tasks;

  $rch->reply("Responses to <task shortcuts> are sent privately.")
    if $event->is_public;
  $rch->private_reply('Known tasks:');

  for my $task (@sorted) {
    my $id = $self->task_by_shortcut($task)->[0]->{id};   # cool, LP
    $rch->private_reply("$task (" . $self->item_uri($id) . ")");
  }
}

sub _handle_todo ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my $desc = $text;

  # If it's for somebody else, it should be a task instead
  if ($desc =~ /^for\s+\S+?:/) {
    return $rch->reply("Sorry, I can only make todo items for you");
  }

  my $res = $self->http_post_for_user($user,
    "/todo_items",
    Content_Type => 'application/json',
    Content => $JSON->encode({ todo_item => { title => $desc } }),
  );

  my $reply = $res->is_success
            ? "I added \"$desc\" to your todo list."
            : "Sorry, I couldn't add that todo... for... some reason.";

  return $rch->reply($reply);
}

sub _handle_todos ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my $todo_res = $self->http_get_for_user($user, "/todo_items");
  return unless $todo_res->is_success;

  my $all_todos = $JSON->decode($todo_res->decoded_content);
  my @todos = grep {; ! $_->{is_done} } @$all_todos;

  return $rch->reply("You don't have any open to-do items.") unless @todos;

  $rch->reply("Responses to <todos> are sent privately.") if $event->is_public;
  $rch->private_reply('Open to-do items:');

  for my $todo (@todos) {
    $rch->private_reply("- $todo->{title}");
  }
}

sub _lp_assignment_is_unestimated {
  my ($self, $assignment) = @_;

  return ($assignment->{low_effort_remaining}  // 0) < 0.00000001
      && ($assignment->{high_effort_remaining} // 0) < 0.00000001;
}

sub damage_report ($self, $event, $rch) {
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

  return $rch->reply("Sorry, I don't know who $who_name is, at least in LiquidPlanner.")
    unless $target && $target->lp_auth_header;

  my $lp_id = $target->lp_id;

  my @to_check = (
    [ inbox  => "📫" => $CONFIG->{liquidplanner}{package}{inbox}  ],
    [ urgent => "🔥" => $CONFIG->{liquidplanner}{package}{urgent} ],
  );

  if ($event->is_public) {
    $rch->reply(
      "I'm generating that report now, and I'll send it to you privately in just a moment.",
      { slack_reaction => { event => $event, reaction => 'hourglass_flowing_sand' } },
    );
  } else {
    $rch->reply(
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

    for my $item ($check_res->payload_list) {
      next unless $item->{type} eq 'Task'; # Whatever. -- rjbs, 2018-06-15
      my ($assign) = grep {; $_->{person_id} == $lp_id }
                     $item->{assignments}->@*;

      next unless $assign and ! $assign->{is_done};

      $total++;
      $unest++ if $self->_lp_assignment_is_unestimated($assign);
    }

    next CHK unless $total;

    my $summary = sprintf "%s %s: %u %s",
      $icon,
      ucfirst $label,
      $total,
      PL_N('task', $total);

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

  $rch->private_reply(
    "Report sent!",
    { slack_reaction => { event => $event, reaction => '-hourglass_flowing_sand' } },
  );

  return $rch->private_reply(
    $reply,
    {
      slack => $slack_summary,
    },
  );
}

sub reload_shortcuts ($self, $event, $rch) {
  $self->_set_projects($self->get_project_shortcuts);
  $self->_set_tasks($self->get_task_shortcuts);
  $rch->reply("Shortcuts reloaded");
  $event->mark_handled;
}

sub _build_package_summary ($self, $package_id, $user) {
  # This is hard-coded because all the iteration-handling code is buried in
  # LP-Tools, and merging that with Synergy without making a big pain right now
  # is... it's not happening this Friday afternoon. -- rjbs, 2018-06-15
  $package_id = 45841484;

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
    $text .= sprintf "%s %s %s %s\n",
      "✨",
      $self->_slack_item_link($c),
      ($c->{is_done} ? "✓" : "•"),
      $c->{name};
  }

  for my $c ($summary->{containers}->@*) {
    $text .= sprintf "%s %s %s %s%s (%u/%u)\n",
      ($c->{type} eq 'Package' ? "\N{PACKAGE}" : "\N{FILE FOLDER}"),
      $self->_slack_item_link($c),
      ($c->{is_done} ? "✓" : "•"),
      $c->{name},
      (($c->{owner_id} != $lp_member_id)
        ? (" _(for @{[ $by_lp{$c->{owner_id}} // 'someone else']})_")
        : q{}),
      $c->{done_tasks},
      $c->{total_tasks},
      ;
  }

  for my $c (@tasks) {
    $text .= sprintf "%s %s %s %s\n",
      "🌀",
      $self->_slack_item_link($c),
      ($c->{is_done} ? "✓" : "•"),
      $c->{name};
  }

  for my $c ($summary->{others}->@*) {
    $text .= sprintf "%s %s %s %s\n",
      "⁉️",
      $self->_slack_item_link($c),
      ($c->{is_done} ? "✓" : "•"),
      $c->{name} . " ($c->{type})";
  }

  chomp $text;
  return $text;
}

sub summarize_iteration ($item, $member_id) {
  my @containers;
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

      push @others, {
        id        => $c->{id},
        type      => $c->{type},
        name      => $c->{name},
        is_done   => $c->{is_done},
      };
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

1;
