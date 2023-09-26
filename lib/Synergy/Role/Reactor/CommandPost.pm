package Synergy::Role::Reactor::CommandPost;

use MooseX::Role::Parameterized;

use experimental 'signatures';

=head1 OVERVIEW

To understand how to use CommandPost, see L<Synergy::CommandPost>.

=cut

use Synergy::CommandPost ();
use Synergy::Logger '$Logger';
use Synergy::PotentialReaction;

role {
  with 'Synergy::Role::Reactor';

  sub potential_reactions_to;

  my $object = Synergy::CommandPost::Object->new;
  method _commandpost => sub { $object };

  method potential_reactions_to => sub ($self, $event) {
    $self->_commandpost->potential_reactions_to($self, $event);
  };

  method help_entries => sub ($self) {
    [ $self->_commandpost->_help_entries ];
  };

  after start => sub ($self, @) {
    my $pkg  = ref $self;
    my $post = $self->_commandpost;

    for my $name ($post->_command_names, $post->_responder_names) {
      unless ($post->_has_registered_help_for($name)) {
        $Logger->log("notice: missing help in $pkg for command $name");
      }
    }
  };
};

1;
