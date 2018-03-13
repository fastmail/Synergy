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
use Synergy::EventHandler::Mux;
use Synergy::EventHandler::TrivialTest;
use Synergy::EventSource::TrivialTest;

my $loop = IO::Async::Loop->new;
my $http = Net::Async::HTTP->new;
$loop->add($http);

my $eh = Synergy::EventHandler::Mux->new({
  eventhandlers => [
    Synergy::EventHandler::TrivialTest->new,
  ]
});

testing_loop($loop);

my $tes = Synergy::EventSource::TrivialTest->new({
  interval  => 1,
  loop      => $loop,
  eventhandler => $eh,
});

wait_for { ($main::x // 0) gt 2 };

my @replies = $tes->replies;

is(@replies, 3, "three replies recorded");
like($replies[1], qr{I heard you, tester}, "...and it's what we expect");

done_testing;
