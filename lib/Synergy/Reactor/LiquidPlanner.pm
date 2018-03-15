use v5.24.0;
package Synergy::Reactor::LiquidPlanner;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use List::Util qw(first);
use Net::Async::HTTP;
use JSON 2 ();
use Time::Duration::Parse;
use Time::Duration;
use utf8;

my $JSON = JSON->new;

my $ERR_NO_LP = "You don't seem to be a LiquidPlanner-enabled user.";
my $WKSP_ID = 14822;
my $LP_BASE = "https://app.liquidplanner.com/api/workspaces/$WKSP_ID";
my $LINK_BASE = "https://app.liquidplanner.com/space/$WKSP_ID/projects/show/";

my %known = (
  timer     => \&_handle_timer,
  task      => \&_handle_task,
 '++'       => \&_handle_plus_plus,
 good       => \&_handle_good,
 gruß       => \&_handle_good,
);

sub listener_specs {
  return {
    name      => "liquid planner",
    method    => "dispatch_event",
    predicate => sub ($self, $event) {
      return unless $event->type eq 'message';
      return unless $event->was_targeted;

      my ($what) = $event->text =~ /^([^\s]+)\s?/;
      $what &&= lc $what;

      return 1 if $known{$what};
      return 1 if $what =~ /^g'day/;    # stupid, but effective
      return 1 if $what =~ /^goo+d/;    # Adrian Cronauer
      return;
    }
  };
}

has projects => (
  isa => 'HashRef',
  traits => [ 'Hash' ],
  handles => {
    project_ids   => 'values',
    projects      => 'keys',
    project_named => 'get',
    project_pairs => 'kv',
  },
  lazy => 1,
  default => sub ($self) {
    $self->get_project_nicknames;
  },
  writer    => '_set_projects',
);

sub start ($self) { $self->projects }

sub get_project_nicknames {
  my ($self) = @_;

  my $query = "/projects?filter[]=custom_field:Nickname is_set&filter[]=is_done is false";
  my $res = $self->http_get_for_master("$LP_BASE$query");
  return {} unless $res && $res->is_success;

  my %project_dict;

  my @projects = @{ $JSON->decode( $res->decoded_content ) };
  for my $project (@projects) {
    # Impossible, right?
    next unless my $nick = $project->{custom_field_values}{Nickname};

    # We'll deal with conflicts later. -- rjbs, 2018-01-22
    $project_dict{ lc $nick } //= [];
    push $project_dict{ lc $nick }->@*, {
      id        => $project->{id},
      nickname  => $nick,
      name      => $project->{name},
    };
  }

  return \%project_dict;
}

sub dispatch_event ($self, $event, $rch) {
  unless ($event->from_user) {
    $rch->reply("Sorry, I don't know who you are.");
    return 1;
  }

  # existing hacks for silly greetings
  my $text = $event->text;
  $text = "good day_au" if $text =~ /\A\s*g'day(?:,?\s+mate)?[1!.?]*\z/i;
  $text = "good day_de" if $text =~ /\Agruß gott[1!.]?\z/i;
  $text =~ s/\Ago{3,}d(?=\s)/good/;

  my ($what, $rest) = $text =~ /^([^\s]+)\s*(.*)/;
  $what &&= lc $what;

  # we can be polite even to non-lp-enabled users
  return $self->_handle_good($event, $rch, $rest) if $what eq 'good';

  unless ($event->from_user->lp_auth_header) {
    $rch->reply($ERR_NO_LP);
    return 1;
  }

  return $known{$what}->($self, $event, $rch, $rest)
}

sub http_get_for_user ($self, $user, @arg) {
  return $self->hub->http_get(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_post_for_user ($self, $user, @arg) {
  return $self->hub->http_post(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_get_for_master ($self, @arg) {
  my ($master) = $self->hub->user_directory->master_users;
  unless ($master) {
    warn "No master users configured\n";
    return;
  }

  $self->http_get_for_user($master, @arg);
}

sub _handle_timer ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

  unless ($res->is_success) {
    warn "failed to get timer: " . $res->as_string . "\n";

    return $rch->reply("I couldn't get your timer. Sorry!");
  }

  my @timers = grep {; $_->{running} }
               @{ $JSON->decode( $res->decoded_content ) };

  my $sy_timer = $user->timer;

  unless (@timers) {
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

  if (@timers > 1) {
    $rch->reply(
      "Woah.  LiquidPlanner says you have more than one active timer!",
    );
  }

  my $timer = $timers[0];
  my $time = concise( duration( $timer->{running_time} * 3600 ) );
  my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$timer->{item_id}");

  my $name = $task_res->is_success
           ? $JSON->decode($task_res->decoded_content)->{name}
           : '??';

  my $url = sprintf "$LINK_BASE/%s", $timer->{item_id};

  return $rch->reply(
    "Your timer has been running for $time, work on: $name <$url>",
  );
}

sub _handle_task ($self, $event, $rch, $text) {
  # because of "new task for...";
  my $what = $text =~ s/\Atask\s+//r;

  my ($target, $name) = $what =~ /\s*for\s+@?(.+?)\s*:\s+(.+)\z/;

  return -1 unless $target and $name;

  my @target_names = split /(?:\s*,\s*|\s+and\s+)/, $target;
  my (@owners, @no_lp, @unknown);
  my %seen;

  my %project_id;
  for my $name (@target_names) {
    my $target = $self->resolve_name($name, $event->from_user->username);

    next if $target && $seen{ $target->username }++;

    my $owner_id = $target ? $target->lp_id : undef;

    # Sadly, the following line is not valid:
    # push(($owner_id ? @owner_ids : @unknown), $owner_id);
    if ($owner_id) {
      push @owners, $target;

      # XXX - From real config! --alh, 2018-03-14
      my $config;
      my $project_id = $config->{liquidplanner}{project}{$target->username};
      warn sprintf "Looking for project for %s found %s\n",
        $target->username, $project_id // '(undef)';

      $project_id{ $project_id }++ if $project_id;
    } elsif ($target) {
      push @no_lp, $target->username;
    } else {
      push @unknown, $name;
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

    return $rch->reply(join(q{  }, @fail));
  }

  my $flags = $self->_strip_name_flags($name);
  my $urgent = $flags->{urgent};
  my $start  = $flags->{running};

  my $via = $rch->channel->describe_event($event);
  my $user = $event->from_user;
  $user = undef unless $user && $user->lp_auth_header;

  my $description = sprintf 'created by %s in response to %s',
    'pizzazz', # XXX -- alh, 2018-03-14
    $via;

  my $project_id = (keys %project_id)[0] if 1 == keys %project_id;

  my $arg = {};

  my $task = $self->_create_lp_task($rch, {
    name   => $name,
    urgent => $urgent,
    user   => $user,
    owners => \@owners,
    description => $description,
    project_id  => $project_id,
  }, $arg);

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

  my $rcpt = join q{ and }, map {; $_->username } @owners;

  my $reply = sprintf
    "Task for $rcpt created: https://app.liquidplanner.com/space/%s/projects/show/%s",
    $WKSP_ID,
    $task->{id};

  if ($start) {
    if ($user) {
      my $res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");
      my $timer = eval { $JSON->decode( $res->decoded_content ); };
      if ($res->is_success && $timer->{running}) {
        $user->last_lp_timer_id($timer->{id});

        $reply =~ s/created:/created, timer running:/;
      } else {
        $reply =~ s/created:/created, timer couldn't be started:/;
      }
    } else {
      $reply =~ s/created:/created, timer couldn't be started:/;
    }
  }

  $rch->reply($reply);
}

sub _handle_plus_plus ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  if (! length $text) {
    return $rch->reply("Thanks, but I'm only as awesome as my creators.");
  }

  my $who = $event->from_user->username;

  return $self->_handle_task($event, $rch, "task for $who: $text");
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

sub __pick_one ($opts) {
  return $opts->[ rand @$opts ];
}

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

  elsif ($what eq 'bye')        { $reply  = __pick_one(\@BYE);
                                  $stop   = 1;
                                  $end_of_day = 1; }

  if ($reply) {
    $reply =~ s/%n/$user->username/ge;
  }

  return $rch->reply($reply) if $reply;

  # TODO: implement expandos
}

sub resolve_name ($self, $name, $who) {
  return unless $name;

  $name = lc $name;
  $name = $who if $name eq 'me' || $name eq 'my' || $name eq 'myself' || $name eq 'i';

  my $user = $self->hub->user_directory->user_by_name($name);
  $user ||= $self->hub->user_directory->user_by_nickname($name);

  return $user;
}

sub _create_lp_task ($self, $rch, $my_arg, $arg) {
  my $config; # XXX REAL CONFIG
  my %container = (
    package_id  => $my_arg->{urgent}
                ? $config->{liquidplanner}{package}{urgent}
                : $config->{liquidplanner}{package}{inbox},
    parent_id   => $my_arg->{project_id}
                ?  $my_arg->{project_id}
                :  undef,
  );

  if ($my_arg->{name} =~ s/#(.*)$//) {
    my $project = lc $1;

    my $projects = $self->project_named($project);

    unless ($projects && @$projects) {
      $arg->{already_notified} = 1;

      return $rch->reply(
          "I am not aware of a project named '$project'. (Try 'projects' "
        . "to see what projects I know about.)",
      );
    }

    if (@$projects > 1) {
      return $rch->reply(
          "More than one LiquidPlanner project has the nickname '$project'. "
        . "Their ids are: "
        . join(q{, }, map {; $_->{id} } @$projects),
      );
    }

    $container{parent_id} = $projects->[0]{id};
  }

  $container{parent_id} = delete $container{package_id}
    unless $container{parent_id};

  my $payload = { task => {
    name        => $my_arg->{name},
    assignments => [ map {; { person_id => $_->lp_id } } @{ $my_arg->{owners} } ],
    description => $my_arg->{description},

    %container,
  } };

  my $as_user = $my_arg->{user} // $self->master_lp_user;

  my $res = $self->http_post_for_user(
    $as_user,
    "$LP_BASE/tasks",
    Content_Type => 'application/json',
    Content => $JSON->encode($payload),
  );

  unless ($res->is_success) {
    warn ">>" . $res->decoded_content . "<<";
    warn $res->as_string;
    return;
  }

  my $task = $JSON->decode($res->decoded_content);

  return $task;
}

sub _strip_name_flags ($self, $name) {
  my ($urgent, $running);
  if ($name =~ s/\s*\(([!>]+)\)\s*\z//) {
    my ($code) = $1;
    $urgent   = $code =~ /!/;
    $running  = $code =~ />/;
  } elsif ($name =~ s/\s*((?::timer_clock:|:hourglass(?:_flowing_sand)?:|:exclamation:)+)\s*\z//) {
    my ($code) = $1;
    $urgent   = $code =~ /exclamation/;
    $running  = $code =~ /timer_clock|hourglass/;
  }

  $_[1] = $name;

  return { urgent => $urgent, running => $running };
}

1;
