#!perl
use v5.36.0;
use utf8;

use lib 'lib', 't/lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Test::EmptyPort qw(empty_port);
use Synergy::Hub;

my $synergy = Synergy::Hub->synergize(
  {
    user_directory  => "t/data/users.yaml",
    server_port     => empty_port(),
    time_zone_names => {
      "America/New_York"  => "🇺🇸",
      "Australia/Sydney"  => "🇦🇺",
      "Europe/Rome"       => "🇻🇦"
    },
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
        todo      => [
          [ send    => { text => "synergy: Bye." } ],
        ],
      }
    },
    reactors => {
      echo => { class => 'Synergy::Reactor::Echo' },
    }
  }
);

sub from_epoch { DateTime->from_epoch(epoch => $_[0]) }

# Fri Jul 13 21:51:37 2018 UTC
my $zero = 1531518697;
my $now  = from_epoch($zero);

binmode *STDOUT, ':encoding(UTF-8)';
binmode *STDERR, ':encoding(UTF-8)';

sub fmt ($date, $arg = {}) {
  return $synergy->format_friendly_date($date, { %$arg, now => $now });
}

sub fmt_epoch ($epoch, $arg = {}) { fmt(from_epoch($epoch), $arg) }

sub date_ok ($date, $expect) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  is($date, $expect, "test for: $expect") or diag "  input date: $date";
}

date_ok(fmt($now), 'today at 21:51 UTC');
date_ok(fmt_epoch($zero  +  3600 * 1), 'today at 22:51 UTC');
date_ok(fmt_epoch($zero  +  3600 * 3), 'tomorrow at 00:51 UTC');
date_ok(fmt_epoch($zero  + 86400 * 1), 'tomorrow at 21:51 UTC');
date_ok(fmt_epoch($zero  + 86400 * 2), 'the day after tomorrow at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 1), 'yesterday at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 2), 'the day before yesterday at 21:51 UTC');

my $norel = { allow_relative => 0 };
date_ok(fmt_epoch($zero  +  3600 * 1, $norel), 'July 13 at 22:51 UTC');
date_ok(fmt_epoch($zero  +  3600 * 3, $norel), 'July 14 at 00:51 UTC');
date_ok(fmt_epoch($zero  + 86400 * 1, $norel), 'July 14 at 21:51 UTC');
date_ok(fmt_epoch($zero  + 86400 * 2, $norel), 'July 15 at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 1, $norel), 'July 12 at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 2, $norel), 'July 11 at 21:51 UTC');

date_ok(fmt_epoch($zero  + 86400 * 6), 'this coming Thursday at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 6), 'this past Saturday at 21:51 UTC');

date_ok(fmt_epoch($zero  + 86400 * 7), 'July 20 at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 7), 'July 6 at 21:51 UTC');

date_ok(fmt_epoch($zero  + 86400 * 30), 'August 12 at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 30), 'June 13 at 21:51 UTC');

date_ok(fmt_epoch($zero  + 86400 * 365), 'July 13, 2019 at 21:51 UTC');
date_ok(fmt_epoch($zero  - 86400 * 365), 'July 13, 2017 at 21:51 UTC');

$synergy->env->time_zone_names->{UTC} = "!";
date_ok(fmt($now), 'today at 21:51 !');

done_testing;
