#!perl
use v5.32.0;
use warnings;
use experimental 'signatures';

use lib 't/lib';

use Test::More;
use Test::Deep;

use IO::Async::Test;
use Synergy::Tester;

package Synergy::TestReactor::Yelling {
  use Moose;
  extends 'Synergy::Reactor::Yelling';

  sub _is_from_correct_slack_channel {
    # Let's just apply this… EVERYWHERE!
    1;
  }

  sub _register_responder_munger {
    return;
  }

  no Moose;
}

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    yelling => {
      class => 'Synergy::TestReactor::Yelling',
      only_targeted => 1,
      slack_synergy_channel_name => 'does-not-matter',
    },
    pref => { class => 'Synergy::Reactor::Preferences' },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
  },
});

sub forbidden_whisper ($message, $desc) {
  my $test_channel = $synergy->channel_named('test-channel');

  my $result = $synergy->run_test_program([
    [ send    => { text => $message }  ],
  ]);

  my @sent = $test_channel->sent_messages;

  cmp_deeply(
    \@sent,
    [ superhashof({ text => "YOU'RE MUMBLING." }) ],
    $desc,
  );

  $test_channel->clear_messages;
}

sub licit_exclamation ($message, $desc) {
  my $test_channel = $synergy->channel_named('test-channel');

  my $result = $synergy->run_test_program([
    [ send    => { text => $message }  ],
  ]);

  my @sent = $test_channel->sent_messages;

  cmp_deeply(
    \@sent,
    [
      # Look, I'm not sure why this isn't a "does not compute" or something,
      # but everything seems to work, so I'd like to figure it out, but right
      # now I'm writing these tests to fix a bug, and there isn't a bug here as
      # far as I know! -- rjbs, 2024-04-07
    ],
    $desc,
  );

  $test_channel->clear_messages;
}

forbidden_whisper("Good morning.", "NO MUMBLING ALLOWED");
licit_exclamation("GOOD MORNING.", "YELLING IS OKAY");

licit_exclamation(
  "GOOD MORNING. :smile:  HAVE A NICE DAY",
  "WE ALSO ACCEPT :emoji:",
);

licit_exclamation(
  "GOOD MORNING. :+1::skin-tone-2: HAVE A NICE DAY",
  "WE ALSO ACCEPT :emoji::with-skin-tones:",
);

done_testing;
