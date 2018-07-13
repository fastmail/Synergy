use v5.24.0;
use warnings;
package Synergy::Util;

use experimental qw(signatures);

use DateTime::Format::Natural;
use Time::Duration::Parse;
use Time::Duration;

use Sub::Exporter -setup => [ qw(
  bool_from_text
  parse_date_for_user
  parse_time_hunk
  pick_one
) ];

# Handles yes/no, y/n, 1/0, true/false, t/f, on/off
sub bool_from_text ($text) {
  return 1 if $text =~ /^(yes|y|true|t|1|on)$/in;
  return 0 if $text =~ /^(no|n|false|f|0|off)/in;

  return (undef, "you can use yes/no, y/n, 1/0, true/false, t/f, or on/off");
}

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

sub pick_one ($opts) {
  return $opts->[ rand @$opts ];
}

1;
