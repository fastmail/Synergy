use v5.28.0;
use warnings;
package Synergy::Test::CommandPost;

use Synergy::Event ();
use Synergy::CommandPost ();
use Synergy::Role::Reactor::CommandPost ();

use experimental 'signatures';

use Sub::Exporter -setup => {
  exports => [ qw(
    create_outpost

    arg_echoer
    tail_echoer

    is_event is_channel is_reactor
  ) ],
  groups  => { default => [ '-all' ] },
};

package Synergy::CommandPost::TestOutpost::Plan {
  use Moose;
  use experimental 'signatures';

  has event  => (is => 'ro', required => 1);
  has _prs   => (is => 'ro', required => 1, init_arg => 'prs');

  sub prs { $_[0]->_prs->@* }

  sub reaction_results ($self) {
    my $event   = $self->event;
    my @results = map {; { name => $_->name, result => scalar $_->handle_event($event) } }
                  $self->prs;

    return @results;
  }

  sub cmp_prs ($self, @expect) {
    my $desc = 'potential reactions met expectations';
    $desc = pop @expect if ! ref $expect[-1];

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    return Test::Deep::cmp_deeply(
      [ $self->prs ],
      [ @expect ],
      $desc,
    );
  }

  sub cmp_results ($self, @expect) {
    my $desc = 'actual reaction results met expectations';
    $desc = pop @expect if ! ref $expect[-1];

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    return Test::Deep::cmp_deeply(
      [ $self->reaction_results ],
      [ @expect ],
      $desc,
    );
  }

  no Moose;
}

package Synergy::CommandPost::TestOutpost {
  sub consider_targeted ($self, $text) {
    my $event = Synergy::Test::CommandPost::_event($text);
    $self->consider_event($event);
  }

  sub consider_untargeted ($self, $text) {
    my $event = Synergy::Test::CommandPost::_event($text, { was_targeted => 0 });
    $self->consider_event($event);
  }

  sub consider_event ($self, $event) {
    my $R = bless [], "FakeReactor";

    return Synergy::CommandPost::TestOutpost::Plan->new({
      event => $event,
      prs   => [ $self->commandpost->potential_reactions_to($R, $event) ],
    });
  }
}

sub is_reactor {
  Test::Deep::any(
    Test::Deep::obj_isa('FakeReactor'),
    Test::Deep::code(sub ($got) { return $got->DOES('Synergy::Role::Reactor') }),
  );
}

sub is_event { Test::Deep::obj_isa('Synergy::Event') }

sub is_channel {
  Test::Deep::code(sub ($got) { return $got->DOES('Synergy::Role::Channel') })
}

sub create_outpost (@todo) {
  my (undef, undef, $line) = caller;
  my $i = 1;
  my $package = "Synergy::CommandPost::TestOutpost::Outpost$line\_" . $i++;

  {
    no strict 'refs';
    @{"$package\::ISA"} = ('Synergy::CommandPost::TestOutpost');
  }

  my $commandpost = Synergy::CommandPost::Object->new;

  Synergy::CommandPost->import(
    { into => $package },
    -default => { commandpost => $commandpost },
  );

  Sub::Install::install_sub({
    code  => sub { $commandpost },
    as    => 'commandpost',
    into  => $package,
  });

  for my $todo (@todo) {
    my ($func, @arg) = @$todo;

    $package->can($func)->(@arg);
  }

  return $package;
}

sub arg_echoer { return sub { [ @_ ] }; }

sub tail_echoer { return sub ($reactor, $channel, @tail) { [ @tail ]; } }

require Synergy::Channel::Test;
my $BOGUS_CHANNEL = Synergy::Channel::Test->new({
  name => 'bogus-test-channel',
});

sub _event ($text, $arg = {}) {
  return Synergy::Event->new({
    type => 'message',
    from_address => 'bogus-from',
    # from_user => $from_user,
    from_channel => $BOGUS_CHANNEL,
    was_targeted => 1,
    conversation_address => 'public',
    %$arg,
    text => $text,
  });
}

1;
