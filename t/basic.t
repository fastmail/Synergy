#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

use IO::Async::Test;
use Synergy::Tester;

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    echo => { class => 'Synergy::Reactor::Echo' },
    pref => { class => 'Synergy::Reactor::Preferences' },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
    charlie => undef,
  },
});

my $result = $synergy->run_test_program([
  [ send    => { text => "synergy: Hi." }  ],
  [ wait    => { seconds => 0.1  }  ],
  [ repeat  => { text => "synergy: Hello?", times => 3, sleep => 0.34 } ],
  [ wait    => { seconds => 0.1  }  ],
  [ send    => { text => "synergy: Bye." } ],
]);

my @sent = $synergy->channel_named('test-channel')->sent_messages;

is(@sent, 5, "five replies recorded");

is(  $sent[0]{address}, 'public',                    "1st: expected address");
like($sent[0]{text},    qr{I heard you, .* "Hi\."},  "1st: expected text");

is(  $sent[4]{address}, 'public',                    "5th: expected address");
like($sent[4]{text},    qr{I heard you, .* "Bye\."}, "5th: expected text");

subtest 'run_process' => sub {
  my $done;

  my $hub = $synergy;

  my $date = -x '/bin/date'     ? '/bin/date'
           : -x '/usr/bin/date' ? '/usr/bin/date'
           : die "This test requires either /bin/date or /usr/bin/date exist.";

  my $f = $hub->run_process([ $date ]);

  $f->on_done(sub ($ec, $stdout, $stderr) {
    $done = 1;
    is($ec, 0, 'process exited successfully');
    my $re = qr{\A[A-Z][a-z]+ \V+ 20[0-9]{2}\Z};
    like($stdout, $re, 'got a reasonable stdout');
    is($stderr, '', 'empty stdout');
  });

  wait_for { $done };
};

done_testing;
