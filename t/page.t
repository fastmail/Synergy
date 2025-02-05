#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

if ($ENV{GITHUB_ACTION}) {
  plan skip_all => "test fails under GitHub Actions at present";
}

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Test::EmptyPort qw(empty_port);
use Path::Tiny ();
use Synergy::Tester;

my $PAGE = "Hello\n\nfriend.";

my $tmpfile = Path::Tiny->tempfile;

my sub new_synergy (%extra_page_reactor_args) {
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
          %extra_page_reactor_args,
        },
      },
      state_dbfile => "$tmpfile",
      server_port => empty_port(),
    }
  );

  return $synergy;
}

subtest "test without page-cc channel" => sub {
  my $synergy = new_synergy();

  # Tests begin here.
  testing_loop($synergy->loop);

  wait_for {
    $synergy->channel_named('test-1')->is_exhausted;
  };

  is_deeply(
    [ $synergy->channel_named('test-1')->sent_messages ],
    [
      { address => 'public', text => 'Page sent to roxy!' },
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
};

subtest "test with page-cc channel" => sub {
  my $synergy = new_synergy(page_cc_channel_name => 'test-1');

  # Tests begin here.
  testing_loop($synergy->loop);

  wait_for {
    $synergy->channel_named('test-1')->is_exhausted;
  };

  is_deeply(
    [ $synergy->channel_named('test-1')->sent_messages ],
    [
      { address => 'Rone',   text => "You are being paged by tester, who says: $PAGE" },
      { address => 'public', text => 'Page sent to roxy!' },
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
};

done_testing;
