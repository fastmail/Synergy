package Synergy::PotentialReaction;

use Moose;

has reactor => (is => 'ro', required => 1);
has is_exclusive => (is => 'ro', required => 1);
has name    => (is => 'ro', required => 1);

sub description { $_[0]->reactor->name . q{/} . $_[0]->name }

has event_handler => (is => 'ro', required => 1);

sub handle_event {
  $_[0]->event_handler->($_[1]);
}

no Moose;
__PACKAGE__->meta->make_immutable;
