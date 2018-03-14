#!perl
use v5.24.0;
use warnings;

use lib 'lib';

use Test::More;

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Hub;
use Synergy::UserDirectory;
use Synergy::Event;
use Synergy::EventHandler::Mux;
use Synergy::EventHandler::TrivialTest;
use Synergy::Channel::TrivialTest;

# Initialize Synergy.
my $synergy = Synergy::Hub->new({
  user_directory => Synergy::UserDirectory->new,
  event_handler  => Synergy::EventHandler::Mux->new({
    event_handlers => [ Synergy::EventHandler::TrivialTest->new ]
  }),
});

$synergy->user_directory->load_users_from_file('t/data/users.yaml');

my $test_channel = Synergy::Channel::TrivialTest->new({
  name      => 'test-channel',
  interval  => 1,
});

$synergy->register_channel($test_channel);

# Start the event loop.
my $loop = IO::Async::Loop->new;
testing_loop($loop);

$synergy->set_loop($loop);

# Tests begin here.
wait_for { ($main::x // 0) gt 2 };

my @replies = $test_channel->replies;

is(@replies, 3, "three replies recorded");
like($replies[1], qr{I heard you, tester}, "...and it's what we expect");

done_testing;
