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
        class     => 'Synergy::Channel::Test',
        todo      => [
          [ send    => { text => "synergy: Hi." }  ],
          [ wait    => { seconds => 1  }  ],
          [ repeat  => { text => "synergy: Hello?", times => 3, sleep => 0.34 } ],
          [ wait    => { seconds => 1  }  ],
          [ send    => { text => "synergy: Bye." } ],
        ],
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
  $synergy->channel_named('test-channel')->is_exhausted;
};

my @replies = $synergy->channel_named('test-channel')->sent_messages;

is(@replies, 5, "five replies recorded");

is(  $replies[0]{address}, 'public',                    "1st: expected address");
like($replies[0]{text},    qr{I heard you, .* "Hi\."},  "1st: expected text");

is(  $replies[4]{address}, 'public',                    "5th: expected address");
like($replies[4]{text},    qr{I heard you, .* "Bye\."}, "5th: expected text");

done_testing;
