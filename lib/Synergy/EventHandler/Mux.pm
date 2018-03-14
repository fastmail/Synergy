use v5.24.0;
package Synergy::EventHandler::Mux;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;

has event_handlers => (
  isa => 'ArrayRef',
  required  => 1,
  traits    => [ 'Array' ],
  handles   => { event_handlers => 'elements' },
);

sub start ($self) {
  $_->start for $self->event_handlers;
  return;
}

sub handle_event ($self, $event, $rch) {
  for my $handler ($self->event_handlers) {
    last if $handler->handle_event($event, $rch);
  }

  return;
}

1;
