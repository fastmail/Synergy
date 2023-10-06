use v5.32.0;
use warnings;
package Synergy::Role::Reactor;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

with 'Synergy::Role::HubComponent';

use Future::AsyncAwait;

has readiness => (
  is    => 'ro',
  lazy  => 1,
  default => sub {
    Future->new;
  }
);

async sub become_ready ($self) {
  await $self->start;
  $self->readiness->done;
}

async sub start {}

requires 'potential_reactions_to';

sub resolve_name ($self, $name, $resolving_user) {
  $self->hub->user_directory->resolve_name($name, $resolving_user);
}

no Moose::Role;
1;
