#!perl
use v5.24.0;
use warnings;

use lib 'lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Hub;

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::TrivialTest',
        interval  => 1,
        prefix    => q{synergy},
      }
    },
    reactors => {
      echo => { class => 'Synergy::Reactor::Echo' },
    }
  }
);

# Tests begin here.
testing_loop($synergy->loop);

wait_for {
  no warnings 'once';
  ($main::x // 0) gt 2
};

my @replies = $synergy->channel_named('test-channel')->sent_messages;

is(@replies, 3, "three replies recorded");

is(  $replies[0]{address}, 'public',                "...expected address");
like($replies[0]{text},    qr{I heard you, tester}, "...expected text");

done_testing;
