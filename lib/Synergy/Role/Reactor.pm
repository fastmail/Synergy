use v5.28.0;
use warnings;
package Synergy::Role::Reactor;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

with 'Synergy::Role::HubComponent';

sub start ($self) { }

sub resolve_name ($self, $name, $resolving_user) {
  $self->hub->user_directory->resolve_name($name, $resolving_user);
}

no Moose::Role;
1;
