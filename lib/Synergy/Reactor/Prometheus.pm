use v5.24.0;
use warnings;
package Synergy::Reactor::Prometheus;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'prometheus',
    method    => 'count_event',
    predicate => sub { 1 },
  };
}

sub start ($self) {
  $self->prom->declare('synergy_events_received_total',
    help => 'Number of events received by reactors',
    type => 'counter',
  );
}

sub count_event ($self, $event) {
  my $from = $event->from_user
           ? $event->from_user->username
           : $event->from_address;

  $self->prom->inc(synergy_events_received_total => {
    channel   => $event->from_channel->name,
    user      => $from,
    in        => $event->from_channel->describe_conversation($event),
    targeted  => $event->was_targeted ? 1 : 0,
  });
}

1;
