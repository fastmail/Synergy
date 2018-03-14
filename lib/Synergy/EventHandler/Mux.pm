use v5.24.0;
package Synergy::EventHandler::Mux;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;
use Try::Tiny;

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
    my $last = try {
      return 1 if $handler->handle_event($event, $rch);
    } catch {
      my $error = $_;

      $error =~ s/\n.*//ms;

      $rch->reply("$handler crashed while handling your message ($error). Sorry");
    };

    last if $last;
  }

  return;
}

1;
