use v5.32.0;
use warnings;
package Synergy::CommandPost;

use experimental qw(isa signatures);
use Synergy::PotentialReaction;

=head1 OVERVIEW

The requirements for a Synergy reactor are very low: you just have to provide a
C<potential_reactions_to> method.  This method is easy to write, but a bit
tedious to write every time you want to write a new reactor.

The CommandPost system is a little framework to let you more easily declare
potential reactions in one of several forms.  It provides
C<potential_reactions_to> for you, working from your declarations.

To use CommandPost, first you need your Reactor class to include the
CommandPost reactor role, like this:

    with 'Synergy::Role::Reactor::CommandPost';

(As usual, try to put all composed roles into a single C<with> statement.)

Then you'll I<also> want to use Synergy::CommandPost, which will import the
helpers you need to declare potential reactors.  These helpers are not just
functions in Synergy::CommandPost, so don't try calling them as fully qualified
names.  You need to import them, beacuse they're all specially generated for
your class.

There are a few kinds of declaration, documented below.

=head1 RESPONDER TYPES

=head2 Commands

  command "eject" => {
    help => "This is the help text for the eject command.",
  } => async sub ($self, $event, $rest) {
    ...
  };

Ideally, you can write most things as C<command>s.  A command matches any
message sent to the bot that starts with the command name followed by a word
boundary.  Commands are exclusive reactions, so they won't work if any other
exclusive reaction matches.

The subroutine provided for the command is invoked with the Synergy::Event that
triggered it, plus the arguments to the command (for which, see below).

The following options can be passed to the command declarator:

=for :list
* help - the help text for the command
* aliases - an arrayref of other names for the command; only the real name
  appears in the help index
* parser - a coderef to parse the rest of the user input

If no C<parser> is provided, then the user's text after the initial command is
passed as the third argument to the method.  In other words, with no parser,
"eject all pods" calls C<< $command_sub->($reactor, $event, "all pods") >>.

If a parser I<is> provided, it will be called with the reactor as the first
argument, the text that followed the command name (like "all pods") as the
second argument, and the event object as the third.  It is expected to return
an arrayref whose elements will be passed as the rest of the arguments.  In
other words, this code…

  command "enjoy" => {
    help    => "It's: enjoy [THING...]",
    parser  => sub ($, $text, $) { split / /, $text }
  } => async sub ($self, $event, @things) {
    for my $thing (@things) {
      $event->reply("I'm glad you enjoy $thing.");
    }
  };

…will reply once for every word after "enjoy".  By the time the parser is
called, Synergy has committed to this reaction as a candidate.

To indicate a failure to parse, you can throw a public L<Synergy::X> exception.

If you need to match only if the whole command can be matched, you should use a
C<responder>, described below.

=head2 Listeners

Listeners are non-exclusive responders.  They get a chance to react to every
single message.

Listeners are intended for things that expand ticket ids, for example.

Declaring listeners is extremely simple:

  listener "name" => async sub ($self, $event) {
    ...
  };

The sub body should return as early as it can tell it doesn't need to reply, or
else reply.

=head2 Responders

Responders are the "well, if nothing else worked" option.

  responder xyzzy => {
    exclusive => 1,
    targeted  => 1,
    help_titles => [ 'advent' ],
    help      => 'There are some Colossal Cave word easter eggs…',
    matcher   => sub ($reactor, $text, @) {
      return [ 'y2' ]     if /y2/;
      return [ 'plugh' ]  if /plugh/;
      return [ 'plover' ] if /plover/;
      return;
    },
  } => sub ($self, $event, $which) {
    ...
  };

The name given to the responder declarator is used in error messages, but isn't
relevant to parsing the event text.

The following options can be passed to the responder declarator:

=for :list
* exclusive - potential reactions to events will be exclusive
* targeted - only targeted-at-the-bot events will be considered
* help, help_titles - the given help text will be indexed under all the given
  titles
* matcher - like a parser that also decides whether to respond; see below

The heart of "should this response fire?" is the C<matcher>.  It's called for
any candidate event and must return either C<undef> or an arrayref.  If it
returns an arrayref, the elements in it will be passed as the arguments to the
subroutine, as with a command responder's C<parser> (see above).  If it returns
C<undef>, the responder should not respond.

The matcher, unlike a command's parser, I<cannot> throw a public Synergy::X to
get an error back to the user.  This is mostly caution, and maybe this can be
made to work in the future after some more consideration.

=head2 Help

This one isn't really a responder, but sometimes your listeners or responders
should be documented under a name that isn't convenient to add in their
declarator.  When that happens, you can:

  help "index-name" => { ... } => "The help text goes here.";

The hashref argument can be omitted.  If provided, it can contain:

=for :list
* aliases - other names under which to file the help; these will be unlisted
* unlisted - if true, the help will be unlisted, meaning it won't be in the
  "help" index

=cut

use Sub::Exporter -setup => {
  groups => { default => \'_generate_command_system' },
};

sub _generate_command_system ($class, $, $arg, $) {
  my $commandpost_override = $arg->{commandpost}; # Used for testing.
  my $get_cmdpost = $commandpost_override
                  ? sub { $commandpost_override }
                  : sub { caller(1)->_commandpost };

  return {
    command => sub ($name, $arg, $code) {
      my $object = $get_cmdpost->();
      $object->add_command($name, $arg, $code);

      if ($arg->{help}) {
        $object->add_help($name, {}, $arg->{help});
      }

      if ($arg->{aliases}) {
        for my $alias ($arg->{aliases}->@*) {
          $object->add_command($alias, $arg, $code);

          if ($arg->{help}) {
            $object->add_help(
              $alias,
              { unlisted => 1 },
              qq{$alias is an alias for $name.  See "help $name".}
            );
          }
        }
      }

      return;
    },
    help => sub ($name, $arg, $text = undef) {
      # Can be called as help(foo => "Text") or help(foo => {...} => "Text")
      if (! defined) {
        $text = $arg;
        $arg  = {};
      }

      my $object = $get_cmdpost->();

      $object->add_help($name, $arg, $text);

      if ($arg->{aliases}) {
        for my $alias ($arg->{aliases}->@*) {
          $object->add_help($alias, { %$arg, unlisted => 1 }, $text);
        }
      }

      return;
    },
    listener => sub ($name, $code) {
      my $object = $get_cmdpost->();
      $object->add_listener($name, {}, $code);
      return;
    },
    responder => sub ($name, $arg, $code) {
      my $object = $get_cmdpost->();
      $object->add_responder($name, $arg, $code);

      if ($arg->{help}) {
        my @help_titles = ($arg->{help_titles} || [ $name ])->@*;
        $object->add_help($_, { _thing_name => $name }, $arg->{help}) for @help_titles;
      }

      return;
    },
  };
}

package Synergy::CommandPost::Object {

  use Moose;

  use experimental qw(isa signatures);

  has commands => (
    isa => 'HashRef',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      _command_named    => 'get',
      _register_command => 'set',
      _command_names    => 'keys',
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

  has responders => (
    isa => 'HashRef',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      _responder_kv    => 'kv',
      _responder_named => 'get',
      _register_responder  => 'set',
      _responder_names     => 'keys',
    },
  );

  BEGIN {
    for my $thing (qw(command listener responder)) {
      my $check = "_$thing\_named";
      my $add   = "_register_$thing";

      Sub::Install::install_sub({
        as    => "add_$thing",
        code  => sub ($self, $name, $arg, $method) {
          # Look, there's not reason you can't actually have two listeners,
          # named Zorch and zorch.  But there's no reason you really ought to
          # do that either.  So don't.  I'll be proscribing any
          # case-insensitive conflict for the same of commands, where it _does_
          # matter. -- rjbs, 2022-01-14
          $name = lc $name;

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

  # This is just bookkeeping so we can report on missing help entries
  has _help_registry => (
    isa       => 'HashRef',
    init_arg  => undef,
    default   => sub { {} },
    traits    => [ 'Hash' ],
    handles   => {
      _register_help => 'set',
      _has_registered_help_for => 'get',
    },
  );

  sub add_help ($self, $name, $arg, $text) {
    my $registry_name = delete $arg->{_thing_name} // $name;
    $self->_register_help($registry_name, 1);

    my $to_store = { %$arg, title => $name, text => $text };
    $self->_add_help($to_store);
    return;
  }

  sub potential_reactions_to ($self, $reactor, $event) {
    my @reactions;
    my $event_was_targeted = $event->was_targeted;

    ### First, is there a command to match the first word of the message?
    if ($event_was_targeted) {
      my ($first, $rest) = split /\s+/, $event->text, 2;
      $first = lc $first;

      if (my $command = $self->_command_named($first)) {
        my $args;

        eval {
          $args = $command->{parser}
                ? ($command->{parser}->($reactor, $rest, $event) || [])
                : [ $rest ];
        };

        unless ($args) {
          my $error = $@;
          if ($error isa Synergy::X && $error->is_public) {
            push @reactions, Synergy::PotentialReaction->new({
              reactor => $reactor,
              name    => "command-$first",
              is_exclusive  => 1,
              event_handler => sub {
                $event->mark_handled;
                $event->error_reply($error->message);
              },
            });
          } else {
            die $error;
          }
        }

        unless (@reactions) {
          # If we already have something in @reactions, it's got to be the
          # error handler above, so don't call the method!
          my $method = $command->{method};

          push @reactions, Synergy::PotentialReaction->new({
            reactor => $reactor,
            name    => "command-$first",
            is_exclusive  => 1,
            event_handler => sub {
              $event->mark_handled;
              $reactor->$method($event, @$args)
            },
          });
        }
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
    my @responder_kv = $self->_responder_kv;

    unless ($event_was_targeted) {
      @responder_kv = grep {; ! $_->[1]{targeted} } @responder_kv;
    }

    for my $responder_pair (@responder_kv) {
      my ($name, $responder) = @$responder_pair;

      my $match = $responder->{matcher}
                ? $responder->{matcher}->($reactor, $event->text, $event)
                : [];
      next unless $match;

      my $method = $responder->{method};

      push @reactions, Synergy::PotentialReaction->new({
        reactor => $reactor,
        name    => "responder-$name",
        is_exclusive  => $responder->{exclusive},
        event_handler => sub { $reactor->$method($event, @$match) },
      });
    }

    return @reactions;
  }

  no Moose;
}

1;
