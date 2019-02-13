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

  parse_switches
  canonicalize_switches
  transliterate
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

sub parse_switches ($string) {
  my @tokens;

  # The tokens we really want:
  #   command   := '/' identifier
  #   safestr   := not-slash+ spaceslash-or-end
  #   quotestr  := '"' ( qchar | not-dquote )* '"' ws-or-end
  #
  # But for now we'll live without quotestr, because it seems very unlikley to
  # come up. -- rjbs, 2019-02-04

  while (length $string) {
    $string =~ s{\A\s+}{}g;
    $string =~ s{\s+\z}{}g;

    if ($string =~ s{ \A /([-a-z]+) (\s* | $) }{}x) {
      push @tokens, [ cmd => $1 ];
      next;
    } elsif ($string =~ s{ \A /(\S+) (\s* | $) }{}x) {
      return (undef, "bogus /command: /$1");
      # push @tokens, [ badcmd => $1 ];
      # next;
    } elsif ($string =~ s{ \A ( [^/]+ ) (\s+/ | $) }{$2}x) {
      push @tokens, [ lit => $1 ];
      next;
    }

    return (undef, "incomprehensible input");
  }

  my @switches;

  my $curr_cmd;
  my $acc_str;

  while (my $token = shift @tokens) {
    if ($token->[0] eq 'badcmd') {
      Carp::confess("unreachable code");
    }

    if ($token->[0] eq 'cmd') {
      if ($curr_cmd) {
        push @switches, [ $curr_cmd, $acc_str ];
      }

      $curr_cmd = $token->[1];
      undef $acc_str;
      next;
    }

    if ($token->[0] eq 'lit') {
      return (undef, "text with no switch") unless $curr_cmd;

      $acc_str = ($acc_str // q{}) . $token->[1];
      next;
    }

    Carp::confess("unreachable code");
  }

  if ($curr_cmd) {
    push @switches, [ $curr_cmd, $acc_str ];
  }

  return (\@switches, undef);
}

sub canonicalize_switches ($switches, $aliases = {}) {
  $aliases->{$_->[0]} && ($_->[0] = $aliases->{$_->[0]}) for @$switches;
  return;
}

sub transliterate ($alphabet, $str) {
  my %trans = (
    latin => sub ($s) { $s },
    rot13 => sub ($s) { $s =~ tr/A-Za-z/N-ZA-Mn-za-m/; $s },
    alexandrian => sub ($s) {
      my %letter = qw(
        a Σ
        b h
        c /
        d ﻝ
        e Ф
        f �
        g �
        h ʖ
        i 𝑜
        j �
        k ✓
        l _
        m ㇵ
        n ߣ
        o □
        p Г
        q �
        r w
        s |
        t Δ
        u ゝ
        v �
        w +
        x ⌿
        y A
        z �
      );

      my @cps = split //, $s;
      return join q{}, map {; exists $letter{$_} ? $letter{$_} : $_ } @cps;
    }
  );

  return $str unless exists $trans{$alphabet};
  return $trans{$alphabet}->($str);
}

1;
