use v5.24.0;
package Synergy::Role::HubComponent;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

has name => (
  is  => 'ro',
  isa => 'Str',
  default => sub ($self, @) { ref $self },
);

has hub => (
  reader => '_get_hub',
  writer => '_set_hub',
  predicate => '_has_hub',
  init_arg  => undef,
  weak_ref  => 1,
  handles   => [ qw( loop ) ],
);

sub hub ($self) {
  my $hub = $self->_get_hub;
  confess "tried to get hub but no hub registered" unless $hub;
  return $hub;
}

sub register_with_hub ($self, $hub) {
  confess "already registered with hub" if $self->_has_hub;
  $self->_set_hub($hub);
  return;
}

sub state { return {} }

sub save_state ($self, $state = $self->state) {
  $self->hub->save_state($self, $state);
}

sub fetch_state ($self) {
  $self->hub->fetch_state($self);
}

no Moose::Role;
1;
