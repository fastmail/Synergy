use v5.24.0;
package Synergy::EventHandler::LiquidPlanner;

use Moose;
with 'Synergy::Role::EventHandler';

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

has http => (
  is => 'ro',
  isa => 'Net::Async::HTTP',
  lazy => 1,
  default => sub {
    my $http = Net::Async::HTTP->new(
      max_connections_per_host => 5, # seems good?
    );

    return $http;
  },
);

sub http_get_for_user ($self, $user, @arg) {
  return $self->http_get(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_get {
  return shift->http_request('GET' => @_);
}

sub http_request ($self, $method, $url, %args) {
  my $content = delete $args{Content};
  my $content_type = delete $args{Content_Type};

  my @args = $url;

  if ($method ne 'GET' && $method ne 'HEAD') {
    push @args, $content // [];
  }

  if ($content_type) {
    push @args, content_type => $content_type;
  }

  push @args, headers => \%args;

  # The returned future will run the loop for us until we return. This makes
  # it asynchronous as far as the rest of the code is concerned, but
  # sychronous as far as the caller is concerned.
  return $self->http->$method(
    @args
  )->on_fail( sub {
    my $failure = shift;
    warn "Failed to $method $url: $failure\n";
  } )->get;
}

has looped => (
  is => 'ro',
  isa => 'Bool',
  writer => '_set_looped',
);

sub start { }

my %known = (
  timer => \&_handle_timer,
);

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  return unless $event->was_targeted;

  my ($what) = $event->text =~ /^([^\s]+)\s?/;
  $what &&= lc $what;

  return unless $known{$what};

  unless ($event->from_user) {
    $rch->reply("Sorry, I don't know who you are.");

    return 1;
  }

  unless ($event->from_user->lp_auth_header) {
    $rch->reply($ERR_NO_LP);

    return 1;
  }

  my $text = $event->text;

  unless ($self->looped) {
    $rch->channel->hub->loop->add($self->http);

    $self->_set_looped(1);
  }

  return $known{$what}->($self, $event, $rch, $text)
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
