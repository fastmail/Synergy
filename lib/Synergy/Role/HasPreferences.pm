use v5.24.0;
package Synergy::Role::HasPreferences;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

requires 'set_preference';

around set_preference => sub ($orig, $self, $event, $name, $value) {
  unless ($self->is_known_preference($name)) {
    my $component_name = $self->name;
    $event->reply("I don't know about the $component_name.<$name> preference");
    $event->mark_handled;
    return;
  }

  $self->$orig($event, $name, $value);
};

# should returns a list of known preference names
requires 'known_preferences';

has _known_preferences => (
  is => 'ro',
  isa => 'HashRef',
  traits => [ 'Hash' ],
  lazy => 1,
  default => sub ($self) {
    return +{ map {; $_ => 1 } $self->known_preferences };
  },
  handles => {
    is_known_preference => 'exists',
  },
);

no Moose::Role;

1;
