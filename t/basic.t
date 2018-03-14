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
        prefix    => q{synergy},
        todo      => [
          [ message => { text => "Hi." }  ],
          [ wait    => { seconds => 1  }  ],
          [ repeat  => { text => "Hello?", times => 3, sleep => 0.34 } ],
          [ wait    => { seconds => 1  }  ],
          [ message => { text => "Bye." } ],
          [ message => { text => "Never received!?" } ],
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
  grep { $_->{text} =~ /Bye\./ }
    $synergy->channel_named('test-channel')->sent_messages
};

my @replies = $synergy->channel_named('test-channel')->sent_messages;

is(@replies, 5, "three replies recorded");

is(  $replies[0]{address}, 'public',                  "...expected address");
like($replies[0]{text},    qr{I heard you, .* Hi\.},  "...expected text");

done_testing;
