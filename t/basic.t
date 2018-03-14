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
use Synergy::Reactor::Echo;
use Synergy::Channel::TrivialTest;

# Initialize Synergy.
my $synergy = Synergy::Hub->new({
  user_directory => Synergy::UserDirectory->new,
});

$synergy->user_directory->load_users_from_file('t/data/users.yaml');

my $test_channel = Synergy::Channel::TrivialTest->new({
  name      => 'test-channel',
  interval  => 1,
  prefix    => q{synergy},
});

$synergy->register_channel($test_channel);

$synergy->register_reactor(Synergy::Reactor::Echo->new);

# Start the event loop.
my $loop = IO::Async::Loop->new;
testing_loop($loop);

$synergy->set_loop($loop);

# Tests begin here.
wait_for { ($main::x // 0) gt 2 };

my @replies = $test_channel->sent_messages;

is(@replies, 3, "three replies recorded");

is(  $replies[0]{address}, 'public',                "...expected address");
like($replies[0]{text},    qr{I heard you, tester}, "...expected text");

done_testing;
