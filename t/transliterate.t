#!perl
use v5.32.0;
use warnings;
use experimental 'signatures';

use utf8;

use Test::More;

use IO::Async::Test;
use Synergy::Tester;

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    echo => { class => 'Synergy::Reactor::Transliterate' },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
    charlie => undef,
  },
});

my $result = $synergy->run_test_program([
  [ send  => { text => "synergy: transliterate to Futhark: Hello world." }  ],
  [ wait  => { seconds => 0.1  }  ],
  [ send  => { text => "synergy: transliterate into italic: This will fail" } ],
]);

my @sent = $synergy->channel_named('test-channel')->sent_messages;

is(@sent, 2, "two replies recorded");

is(  $sent[0]{address}, 'public',         "1st: expected address");
like($sent[0]{text},    qr{ᚺᛖᛚᛚᛟ ᚹᛟᚱᛚᛞ.}, "1st: expected text");

is(  $sent[1]{address}, 'public',         "1st: expected address");
like(
  $sent[1]{text},
  qr{didn't understand that}, # as opposed to "unknown alphabet"
  "2nd: expected text",
);

done_testing;
