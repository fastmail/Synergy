use v5.24.0;
package Synergy::Role::Reactor;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

use Synergy::Listener;

has name => (
  is  => 'ro',
  isa => 'Str',
  default => sub ($self, @) { ref $self },
);

has listeners => (
  isa => 'ArrayRef',
  traits  => [ 'Array' ],
  handles => { listeners => 'elements' },
  default => sub ($self, @) {
    # { name, predicate, exclusive, method }
    my @listeners = map {;
      Synergy::Listener->new({
        $_->%{ qw( name predicate exclusive method ) }
      });
    } $self->listener_specs;

    return \@listeners;
  },
);

sub register_with_hub ($self, $hub) { }
sub start             ($self) { }

no Moose::Role;
1;
