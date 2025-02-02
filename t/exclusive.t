#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::EmptyPort qw(empty_port);
use Synergy::Tester;

my $synergy = Synergy::Tester->new_tester({
  default_from => 'alice',
  users => {
    alice   => undef,
    charlie => undef,
  },
  reactors => {
    help1 => { class => 'Synergy::Reactor::Help' },
    help2 => { class => 'Synergy::Reactor::Help' },
    echo => { class => 'Synergy::Reactor::Echo' },
  }
});

my $result = $synergy->run_test_program([
  [ send    => { text => "synergy: help" }  ],
]);

my @replies = $synergy->channel_named('test-channel')->sent_messages;

is(@replies, 1, "one reply recorded");

is($replies[0]{address}, 'public', "1st: expected address");
is(
  $replies[0]{text},
  join(qq{\n},
    "Sorry, I find that message ambiguous.",
    "The following reactors matched: echo/listener-echo, help1/command-help (exclusive), help2/command-help (exclusive)"),
  "ambiguous commands are rejected",
);

done_testing;
