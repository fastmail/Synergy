use v5.28.0;
use warnings;
package Synergy::Role::Reactor::EasyListening;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

with 'Synergy::Role::Reactor';

has listeners => (
  isa => 'ArrayRef',
  traits  => [ 'Array' ],
  handles => { listeners => 'elements' },
  lazy => 1,
  default => sub ($self, @) {
    my @listeners = $self->listener_specs;

    return \@listeners;
  },
);

around help_entries => sub ($orig, $self, @rest) {
  my $entries = $self->$orig(@rest);
  return [
    @$entries,
    (map {; @{ $_->{help_entries} // [] } } $self->listeners),
  ];
};

sub potential_reactions_to ($self, $event) {
  my @matches = $self->listeners;

  unless ($event->was_targeted) {
    @matches = grep {; ! $_->{targeted} } @matches;
  }

  @matches = grep {; $_->{predicate}->($self, $event) } @matches;

  return unless @matches;
  my $reactor = $self;

  my @potential = map {;
    my $method = $_->{method};
    require Synergy::PotentialReaction;
    Synergy::PotentialReaction->new({
      reactor => $reactor,
      is_exclusive => $_->{exclusive},
      name         => $_->{name},
      event_handler => sub { $reactor->$method($_[0]) },
    });
  } @matches;

  return @potential;
}

no Moose::Role;
1;
