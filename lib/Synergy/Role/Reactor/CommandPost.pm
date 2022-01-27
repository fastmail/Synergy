package Synergy::Role::Reactor::CommandPost;

use MooseX::Role::Parameterized;

use experimental 'signatures';

use Synergy::CommandPost ();
use Synergy::PotentialReaction;

role {
  my $object = Synergy::CommandPost::Object->new;
  method _commandpost => sub { $object };

  method potential_reactions_to => sub ($self, $event) {
    $self->_commandpost->potential_reactions_to($self, $event);
  };

  method help_entries => sub ($self) {
    [ $self->_commandpost->_help_entries ];
  };
};

1;
