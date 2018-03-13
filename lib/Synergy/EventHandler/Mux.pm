use v5.24.0;
package Synergy::EventHandler::Mux;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;

has eventhandlers => (
  isa => 'ArrayRef',
  required  => 1,
  traits    => [ 'Array' ],
  handles   => { eventhandlers => 'elements' },
);

sub handle_event ($self, $event, $rch) {
  for my $handler ($self->eventhandlers) {
    last if $handler->handle_event($event, $rch);
  }

  return;
}

1;
