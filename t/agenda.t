#!perl
use v5.24.0;
use warnings;

use lib 'lib', 't/lib';

use Test::More;

use Synergy::Tester;

my $result = Synergy::Tester->testergize({
  reactors => {
    agenda => { class => 'Synergy::Reactor::Agendoizer' },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
    charlie => undef,
  },
  todo => [
    [ send    => { text => "synergy: agenda list" } ],
    [ wait    => { seconds => 0.1  }  ],
  ],
});

my @sent = $result->synergy->channel_named('test-channel')->sent_messages;

ok(
  (grep {; $_->{text} =~ /\QYou don't have any available agendas./ } @sent),
  "got the expected replies",
);

done_testing;
