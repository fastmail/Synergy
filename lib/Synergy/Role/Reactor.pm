use v5.28.0;
use warnings;
package Synergy::Role::Reactor;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

with 'Synergy::Role::HubComponent';

sub help_entries {
  # Generally here to be overridden.  Should return an arrayref of help
  # entries, each with { title => ..., text => ... }
  return [];
}

sub start ($self) { }

sub resolve_name ($self, $name, $resolving_user) {
  $self->hub->user_directory->resolve_name($name, $resolving_user);
}

no Moose::Role;
1;
