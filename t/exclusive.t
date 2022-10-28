#!perl
use v5.28.0;
use warnings;

use lib 'lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::EmptyPort qw(empty_port);
use Synergy::Hub;

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    server_port => empty_port(),
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
        todo      => [
          [ send    => { text => "synergy: help" }  ],
          [ wait    => { seconds => 0.1  }  ],
        ],
      }
    },
    reactors => {
      help1 => { class => 'Synergy::Reactor::Help' },
      help2 => { class => 'Synergy::Reactor::Help' },
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

is(@replies, 1, "one reply recorded");

is($replies[0]{address}, 'public', "1st: expected address");
is(
  $replies[0]{text},
  join(qq{\n},
    "Sorry, I find that message ambiguous.",
    "The following reactors matched: echo/listener-echo, help1/help (exclusive), help2/help (exclusive)"),
  "ambiguous commands are rejected",
);

done_testing;
