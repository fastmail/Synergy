#!perl
use v5.32.0;
use warnings;

use lib 'lib', 't/lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::EmptyPort qw(empty_port);
use Path::Tiny ();
use Synergy::Tester;

my $PAGE = "Hello\n\nfriend.";

my $result = Synergy::Tester->testergize({
  users => {
    roxy => {
      extra_identities => {
        'test-1' => 'Rone',
        'test-2' => 'Rtwo',
      },
    },
    stormer => {
      extra_identities => {
        'test-1' => 'Mone',
        'test-2' => 'Mtwo',
      }
    },
  },
  todo      => [
    [ send    => { text => "synergy: page roxy: $PAGE" }  ],
    [ wait    => { seconds => 0.1  }  ],
  ],
  extra_channels => {
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
});

is_deeply(
  [ $result->synergy->channel_named('test-channel')->sent_messages ],
  [
    { address => 'public', text => 'Page sent to roxy!' },
  ],
  "sent a reply on the chat channel",
);

is_deeply(
  [ $result->synergy->channel_named('test-2')->sent_messages ],
  [
    { address => 'Rtwo', text => "tester says: $PAGE" },
  ],
  "sent a page on the page channel",
);

done_testing;
