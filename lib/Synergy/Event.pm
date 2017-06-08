use v5.24.0;
package Synergy::Event;
use Moose;

use experimental qw(signatures);

use namespace::autoclean;

has type => (is => 'ro', isa => 'Str', required => 1);
has text => (is => 'ro', isa => 'Str', required => 1); # clearly per-type

sub BUILD ($self, @) {
  confess "only 'message' events exist for now"
    unless $self->type eq 'message';
}

1;
