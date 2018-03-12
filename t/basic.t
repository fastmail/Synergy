#!perl
use v5.24.0;
use warnings;

use lib 'lib';

use Test::More;

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Event;
use Synergy::EventHandler;
use Synergy::EventSource::TrivialTest;
use Synergy::EventSource::Slack;
use Synergy::ReplyChannel::Test;
use Synergy::ReplyChannel::Stdout;

use Synergy::External::Slack;

my $eh   = Synergy::EventHandler->new;
my $loop = IO::Async::Loop->new;
my $http = Net::Async::HTTP->new;
$loop->add($http);

testing_loop($loop);

package TES {
  use Moose;
  extends 'Synergy::EventSource::TrivialTest';

  has rch => (
    is => 'ro',
    init_arg => undef,
    default  => sub { Synergy::ReplyChannel::Test->new }
  );

  no Moose;
}

my $tes = TES->new({
  interval  => 1,
  loop      => $loop,
  eventhandler => $eh,
});

wait_for { ($main::x // 0) gt 2 };

my @replies = $tes->rch->replies;

is(@replies, 1, "one reply still cached");
like($replies[0][1], qr{I heard you, tester}, "...and it's what we expect");

done_testing;
