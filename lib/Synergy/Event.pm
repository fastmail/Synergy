use v5.24.0;
package Synergy::Event;
use Moose;

use experimental qw(signatures);

use namespace::autoclean;

has type => (is => 'ro', isa => 'Str', required => 1);
has text => (is => 'ro', isa => 'Str', required => 1); # clearly per-type

has from_channel => (
  is => 'ro',
  does => 'Synergy::Role::Channel',
  required => 1,
);

has from_address => (
  is => 'ro',
  isa => 'Defined',
  required => 1,
);

has from_user => (
  is => 'ro',
  isa => 'Synergy::User',
);

has transport_data => (
  is => 'ro',
);

has was_targeted => (
  is => 'ro',
  isa => 'Bool',
  default => 1,
);

has is_public => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

sub is_private ($self) { ! $self->is_public }

sub BUILD ($self, @) {
  confess "only 'message' events exist for now"
    unless $self->type eq 'message';
}

1;
