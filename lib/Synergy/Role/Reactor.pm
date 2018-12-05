use v5.24.0;
use warnings;
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

sub start ($self) { }

sub resolve_name ($self, $name, $resolving_user) {
  $self->hub->user_directory->resolve_name($name, $resolving_user);
}

no Moose::Role;
1;
