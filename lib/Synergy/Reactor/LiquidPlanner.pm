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

my $JSON = JSON->new;

my $ERR_NO_LP = "You don't seem to be a LiquidPlanner-enabled user.";
my $WKSP_ID = 14822;
my $LP_BASE = "https://app.liquidplanner.com/api/workspaces/$WKSP_ID";
my $LINK_BASE = "https://app.liquidplanner.com/space/$WKSP_ID/projects/show/";

my %known = (
  timer => \&_handle_timer,
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

      return unless $known{$what};

      return 1;
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
  default => sub {
    $_[0]->get_project_nicknames;
  },
  writer    => '_set_projects',
);

sub get_project_nicknames {
  my ($self) = @_;

  my $query = "/projects?filter[]=custom_field:Nickname is_set&filter[]=is_done is false";
  my $res = $self->http_get_for_master("$LP_BASE$query");
  return unless $res->is_success;

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

  unless ($event->from_user->lp_auth_header) {
    $rch->reply($ERR_NO_LP);

    return 1;
  }

  my ($what) = $event->text =~ /^([^\s]+)\s?/;
  $what &&= lc $what;

  return $known{$what}->($self, $event, $rch, $what)
}

sub http_get_for_user ($self, $user, @arg) {
  return $self->hub->http_get(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_get_for_master ($self, @arg) {
  my $master = $self->hub->user_directory->user_by_name('alh');
  $self->http_get_for_user($master, @arg);
}

sub _handle_timer ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  my sub reply ($text) {
    $rch->reply($text);

    return 1;
  }

  return reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

  unless ($res->is_success) {
    warn "failed to get timer: " . $res->as_string . "\n";

    return reply("I couldn't get your timer. Sorry!");
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

    return reply($msg);
  }

  if (@timers > 1) {
    reply(
      "Woah.  LiquidPlanner says you have more than one active timer!",
    );
  }

  my $timer = $timers[0];
  my $time = concise( duration( $timer->{running_time} * 3600 ) );
  my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$timer->{item_id}");

  my $name = $task_res->is_success
           ? $JSON->decode($task_res->decoded_content)->{name}
           : '??';

  my $url = sprintf "https://app.liquidplanner.com/space/%s/projects/show/%s",
    $WKSP_ID,
    $timer->{item_id};

  return reply(
    "Your timer has been running for $time, work on: $name <$url>",
  );
}

1;
