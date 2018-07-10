use v5.24.0;
package Synergy::Reactor::Status;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);
use Time::Duration::Parse;
use Time::Duration;

sub listener_specs ($reactor) {
  return (
    {
      name      => 'status',
      method    => 'handle_status',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /^status\s+(\w+)\s*$/i
      },
    },
    {
      name      => "listen-for-activity",
      method    => "handle_activity",
      predicate => sub ($self, $e) {
        return unless $e->is_public;
        return 1;
      },
    },
  );
}

has monitored_channel_name => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_monitored_channel',
);

has _last_activity => (
  isa     => 'HashRef',
  default => sub {  {}  },
  traits  => [ 'Hash' ],
  handles => {
    record_last_activity_for => 'set',
    last_activity_for        => 'get',
  },
);

sub handle_activity ($self, $event) {
  return unless $self->has_monitored_channel;
  return unless $self->monitored_channel_name eq $event->from_channel->name;

  my $username = $event->from_user->username;
  $self->record_last_activity_for($username, {
    when => $event->time,
    uri  => scalar $event->event_uri,
  });
  return;
}

sub handle_status ($self, $event) {
  (undef, my $who_name) = split /\s/, $event->text;

  my $who = $self->resolve_name($who_name, $event->from_user);

  $event->mark_handled;

  unless ($who) {
    return $event->reply(qq{Sorry, I don't know who "$who_name" is.});
  }

  if (my $last = $self->last_activity_for($who->username)) {
    return $event->reply(
      sprintf "I last saw activity from %s at %s%s.",
        $who->username,
        $event->from_user->format_datetime(
          DateTime->from_epoch(epoch => $last->{when})
        ),
        ($last->{uri} ? ": $last->{uri}" : q{}),
    );
  }

  return $event->reply(
    sprintf "I've never seen any activity for %s.", $who->username,
  );
}

1;
