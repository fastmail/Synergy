use v5.24.0;
package Synergy::Role::Reactor;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

use Synergy::Listener;

with 'Synergy::Role::HubComponent';

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

sub start ($self) { }

sub state { return {} }

sub save_state ($self) {
  $self->hub->save_state($self, $self->state);
}

sub fetch_state ($self) {
  $self->hub->fetch_state($self);
}

sub resolve_name ($self, $name, $resolving_user) {
  $self->hub->user_directory->resolve_name($name, $resolving_user);
}

no Moose::Role;
1;
