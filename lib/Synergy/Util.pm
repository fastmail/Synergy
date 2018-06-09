use v5.24.0;
use warnings;
package Synergy::Util;

use experimental qw(signatures);

use DateTime::Format::Natural;
use Time::Duration::Parse;
use Time::Duration;

use Sub::Exporter -setup => [ qw(
  parse_time_hunk
  parse_date_for_user
  pick_one
) ];

sub parse_time_hunk ($hunk, $user) {
  my ($prep, $rest) = split ' ', $hunk, 2;

  if ($prep eq 'for') {
    my $dur;
    $rest =~ s/^an?\s+/1 /;
    my $ok = eval { $dur = parse_duration($rest); 1 };
    return unless $ok;
    return time + $dur;
  }

  if ($prep eq 'until') {
    # XXX get the user in here -- rjbs, 2016-12-26
    my $dt = eval { parse_date_for_user($rest, $user) };
    return unless $dt;
    return $dt->epoch;
  }

  return;
}

# XXX This should go into Synergy::Util or something
sub parse_date_for_user ($str, $user) {
  my $tz = $user ? $user->time_zone : 'America/New_York';

  state %parser_for;
  $parser_for{$tz} //= DateTime::Format::Natural->new(
    prefer_future => 1,
    time_zone     => $tz,
  );

  my $dt = $parser_for{$tz}->parse_datetime($str);

  if ($dt->hour == 0 && $dt->minute == 0 && $dt->second == 0) {
    $dt->set(hour => 9);
  }

  return $dt;
}

sub pick_one ($opts) {
  return $opts->[ rand @$opts ];
}

1;
