use v5.24.0;
use warnings;
package Synergy::CommandPost;

use experimental 'signatures';

use Synergy::PotentialReaction;

use Sub::Exporter -setup => {
  groups => { default => \'_generate_command_system' },
};

package Synergy::CommandPost::Object {
  use Moose;

  use experimental 'signatures';

  has is_final => (is => 'rw');

  has commands => (
    isa => 'HashRef',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      _command_named    => 'get',
      _register_command => 'set',
    },
  );

  has listeners => (
    isa => 'HashRef',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      _listener_kv    => 'kv',
      _listener_named => 'get',
      _register_listener  => 'set',
    },
  );

  has reactions => (
    isa => 'HashRef',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      _reaction_kv    => 'kv',
      _reaction_named => 'get',
      _register_reaction  => 'set',
    },
  );

  BEGIN {
    for my $thing (qw(command listener reaction)) {
      my $check = "_$thing\_named";
      my $add   = "_register_$thing";

      Sub::Install::install_sub({
        as    => "add_$thing",
        code  => sub ($self, $name, $arg, $method) {
          Carp::confess("already have a $thing named $name")
            if $self->$check($name);

          my $to_store = { method => $method, %$arg };

          $self->$add($name, $to_store);

          return;
        }
      });
    }
  }

  has help => (
    isa => 'ArrayRef',
    init_arg  => undef,
    default   => sub {  []  },
    traits    => [ 'Array' ],
    handles   => {
      _add_help => 'push',
      _help_entries => 'elements',
    },
  );

  sub add_help ($self, $name, $arg, $text) {
    my $to_store = { %$arg, title => $name, text => $text };
    $self->_add_help($to_store);
    return;
  }

  sub potential_reactions_to ($self, $reactor, $event) {
    my @reactions;
    my $targeted = $event->was_targeted;

    ### First, is there a command to match the first word of the message?
    my ($first, $rest) = split /\s+/, $event->text, 2;

    if ($targeted) {
      if (my $command = $self->_command_named($first)) {
        my $method = $command->{method};

        push @reactions, Synergy::PotentialReaction->new({
          reactor => $reactor,
          name    => "command-$first",
          is_exclusive  => 1,
          event_handler => sub {
            $event->mark_handled;
            $reactor->$method($event, $rest)
          },
        });
      }
    }

    ### Next, allow all the listeners to have a crack at the event.
    for my $listener_pair ($self->_listener_kv) {
      my $method = $listener_pair->[1]{method};

      push @reactions, Synergy::PotentialReaction->new({
        reactor => $reactor,
        name    => "listener-$listener_pair->[0]",
        is_exclusive  => 0,
        event_handler => sub { $reactor->$method($event) },
      });
    }

    ### Finally, reactions are the last-resort flexible option.
    my @reaction_kv = $self->_reaction_kv;
    @reaction_kv = grep {; $_->[1]{targeted} } @reaction_kv if ! $targeted;
    for my $reaction_pair (@reaction_kv) {
      my ($name, $reaction) = @$reaction_pair;
      my $match = $reaction->{matcher}->($event);
      next unless $match;

      my $method = $reaction->{method};

      push @reactions, Synergy::PotentialReaction->new({
        reactor => $reactor,
        name    => "reaction-$name",
        is_exclusive  => $reaction->{exclusive},
        event_handler => sub { $reactor->$method($event, @$match) },
      });
    }

    return @reactions;
  }

  no Moose;
}

sub _generate_command_system ($class, $, $arg, @) {
  my $object = Synergy::CommandPost::Object->new;
  return {
    potential_reactions_to => sub ($reactor, $event) {
      $object->potential_reactions_to($reactor, $event);
    },
    help_entries => sub ($self) {
      [ $object->_help_entries ];
    },
    command => sub ($name, $arg, $code) {
      $object->add_command($name, $arg, $code);

      if ($arg->{help}) {
        $object->add_help($name, {}, $arg->{help});
      }

      return;
    },
    help => sub ($name, $text) {
      $object->add_help($name, {}, $text);
      return;
    },
    listener => sub ($name, $code) {
      $object->add_listener($name, {}, $code);

      return;
    },
    reaction => sub ($name, $arg, $code) {
      $object->add_reaction($name, $arg, $code);

      if ($arg->{help}) {
        $object->add_help($name, {}, $arg->{help});
      }

      return;
    },
  };
}

1;
