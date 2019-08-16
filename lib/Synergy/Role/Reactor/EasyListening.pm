use v5.24.0;
use warnings;
package Synergy::Role::Reactor::EasyListening;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

use Synergy::Listener;

with 'Synergy::Role::Reactor';

has listeners => (
  isa => 'ArrayRef',
  traits  => [ 'Array' ],
  handles => { listeners => 'elements' },
  default => sub ($self, @) {
    my @listeners;
    for my $spec ($self->listener_specs) {
      push @listeners, Synergy::Listener->new({
        reactor => $self,
        $spec->%{ qw( exclusive name predicate method ) },
        (exists $spec->{help_entries} ? (help_entries => $spec->{help_entries})
                                      : ()),
      });
    }

    return \@listeners;
  },
);

around help_entries => sub ($orig, $self, @rest) {
  my $entries = $self->$orig(@rest);
  return [
    @$entries,
    (map {; $_->help_entries->@* } $self->listeners),
  ];
};

sub listeners_matching ($self, $event) {
  return grep {; $_->matches_event($event) } $self->listeners;
}

no Moose::Role;
1;
