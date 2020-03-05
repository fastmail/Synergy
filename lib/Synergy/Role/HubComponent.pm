use v5.24.0;
use warnings;
package Synergy::Role::HubComponent;

use Moose::Role;
use Moose::Util::TypeConstraints;

use experimental qw(signatures);
use namespace::clean;

subtype 'IdentifierStr'
  => as 'Str'
  => where { $_ =~ /\A[_a-z][-_a-z0-9]*\z/i }
  => message { "Hub component names must be valid identifiers: '$_' is not." };

has name => (
  is  => 'ro',
  isa => 'IdentifierStr',
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

sub has_preferences ($self) {
  return 0 unless $self->does('Synergy::Role::HasPreferences');
  return !! ($self->preference_names)[0];
}

no Moose::Role;
1;
