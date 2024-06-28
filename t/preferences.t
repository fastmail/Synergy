#!perl
use v5.32.0;
use warnings;
use experimental 'signatures';

use lib 't/lib';

use Test::Deep;
use Test::More;

use IO::Async::Test;
use Synergy::Tester;

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    pref      => { class => 'Synergy::Reactor::Preferences' },
    preftest  => { class => 'Synergy::Test::Reactor::PreferenceTest' },
  },
  default_from => 'stormer',
  users => {
    stormer => undef,
    roxy    => undef,
  },
});


my $result = $synergy->run_test_program([
  [ send  => { text => "synergy: dump my prefs" }  ],
  [ wait  => { seconds => 0.1  }  ],
  [ send  => { text => "synergy: set my preftest.bool-pref to true"} ],
  [ wait  => { seconds => 0.1  }  ],
  [ send  => { text => "synergy: dump my prefs" }  ],
  [ wait  => { seconds => 0.1  }  ],
]);

my @sent = $synergy->channel_named('test-channel')->sent_messages;

is(@sent, 3, "three replies recorded");

cmp_deeply(
  \@sent,
  [
    superhashof({
      address => 'public',
      text  => re(qr{\bpreftest\.bool-pref: 0\b}m),
    }),
    superhashof({
      address => 'public',
      text    => 'Your preftest.bool-pref setting is now 1.',
    }),
    superhashof({
      address => 'public',
      text  => re(qr{\bpreftest\.bool-pref: 1\b}m),
    })
  ],
  "all replies are what we expect",
);

done_testing;
