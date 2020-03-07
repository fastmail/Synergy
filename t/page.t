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
use Net::EmptyPort qw(empty_port);
use Path::Tiny ();
use Synergy::Hub;

my $PAGE = "Hello\n\nfriend.";

my $tmpfile = Path::Tiny->tempfile;

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users-page.yaml",
    channels => {
      'test-1' => {
        class     => 'Synergy::Channel::Test',
        todo      => [
          [ send    => { text => "synergy: page roxy: $PAGE" }  ],
          [ wait    => { seconds => 0.1  }  ],
        ],
      },
      'test-2' => {
        class     => 'Synergy::Channel::Test',
        prefix    => q{synergy},
      },
      'test-3' => {
        class     => 'Synergy::Channel::Test',
        prefix    => q{synergy},
      }
    },
    reactors => {
      page => {
        class => 'Synergy::Reactor::Page',
        page_channel_name => 'test-2',
        pushover_channel_name => 'test-3',
      },
    },
    state_dbfile => "$tmpfile",
    server_port => empty_port(),
  }
);

# Tests begin here.
testing_loop($synergy->loop);

wait_for {
  $synergy->channel_named('test-1')->is_exhausted;
};

is_deeply(
  [ $synergy->channel_named('test-1')->sent_messages ],
  [
    { address => 'public', text => 'Page sent!' },
  ],
  "sent a reply on the chat channel",
);

is_deeply(
  [ $synergy->channel_named('test-2')->sent_messages ],
  [
    { address => 'Rtwo', text => "tester says: $PAGE" },
  ],
  "sent a page on the page channel",
);

done_testing;
