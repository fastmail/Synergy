#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

use IO::Async::Test;
use Synergy::Tester;

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    echo => {
      class => 'Synergy::Reactor::Echo',
      only_targeted => 1,
    },
    pref => { class => 'Synergy::Reactor::Preferences' },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
  },
});

my $result = $synergy->run_test_program([
  [ send    => { text => "Good morning." }  ],
  [ wait    => { seconds => 0.1  }  ],
  [ send    => { text => "synergy: Good morning." }  ],
  [ wait    => { seconds => 0.1  }  ],
  [ send    => { text => "synergy Good morning." } ],
  [ wait    => { seconds => 0.1  }  ],
  [ send    => { text => "synergy, Good morning." } ],
]);

my @sent = $synergy->channel_named('test-channel')->sent_messages;

is(@sent, 3, "three replies recorded");

is(  $sent[0]{address}, 'public',         "1st: expected address");
like($sent[0]{text},    qr{I heard you, .* "Good morning\."},  "1st: expected text");

is(  $sent[1]{address}, 'public',         "2nd: expected address");
like($sent[1]{text},    qr{I heard you, .* "Good morning\."},  "2nd: expected text");

is(  $sent[2]{address}, 'public',         "3rd: expected address");
like($sent[2]{text},    qr{I heard you, .* "Good morning\."},  "3rd: expected text");

done_testing;
