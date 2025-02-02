use v5.36.0;
package Synergy::Reactor::Prometheus;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

after register_with_hub => sub ($self, $hub) {
  $self->prom->declare('synergy_events_received_total',
    help => 'Number of events received by Synergy',
    type => 'counter',
  );
};

listener count_events => async sub ($self, $event) {
  my $from = $event->from_user
           ? $event->from_user->username
           : $event->from_address;

  $self->prom->inc(synergy_events_received_total => {
    channel   => $event->from_channel->name,
    user      => $from,
    in        => $event->from_channel->describe_conversation($event),
    targeted  => $event->was_targeted ? 1 : 0,
  });

  return;
};

1;
