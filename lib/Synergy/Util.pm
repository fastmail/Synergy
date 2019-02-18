use v5.24.0;
use warnings;
package Synergy::Util;

use utf8;
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

  known_alphabets
  transliterate
) ];

# Handles yes/no, y/n, 1/0, true/false, t/f, on/off
sub bool_from_text ($text) {
  return 1 if $text =~ /^(yes|y|true|t|1|on|nahyeah)$/in;
  return 0 if $text =~ /^(no|n|false|f|0|off|yeahnah)$/in;

  return (undef, "you can use yes/no, y/n, 1/0, true/false, t/f, on/off, or yeahnah/nahyeah");
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

my %Trans = (
  latin => sub ($s) { $s },
  rot13 => sub ($s) { $s =~ tr/A-Za-z/N-ZA-Mn-za-m/; $s },
  alexandrian => sub ($s) {
    my %letter = qw(
      a Σ     b h     c /     d ﻝ     e Ф
      f �     g �     h ʖ     i 𝑜     j �
      k ✓     l _     m ㇵ    n ߣ     o □
      p Г     q �     r w     s |     t Δ
      u ゝ    v �     w +     x ⌿     y A
      z �
    );

    my @cps = split //, $s;
    return join q{}, map {; exists $letter{lc $_} ? $letter{lc $_} : $_ } @cps;
  },
  futhark => sub ($s) {
    my $map = {
      'a' => 'ᚨ',
      'b' => 'ᛒ',
      'c' => 'ᚲ',
      'd' => 'ᛞ',
      'e' => 'ᛖ',
      'ei' => 'ᛇ',
      'f' => 'ᚠ',
      'g' => 'ᚷ',
      'h' => 'ᚺ',
      'i' => 'ᛁ',
      'j' => 'ᛃ',
      'k' => 'ᚲ',
      'l' => 'ᛚ',
      'm' => 'ᛗ',
      'n' => 'ᚾ',
      'o' => 'ᛟ',
      'p' => 'ᛈ',
      'q' => 'ᚲᚹ',
      'r' => 'ᚱ',
      's' => 'ᛊ',
      't' => 'ᛏ',
      'th' => 'ᚦ',
      'u' => 'ᚢ',
      'v' => 'ᚢ',
      'w' => 'ᚹ',
      'x' => 'ᚲᛊ',
      'y' => 'ᛃ',
      'z' => 'ᛉ',
    };
    my $transliterated = '';
    LETTER:
    while ( $s ) {
      MATCH:
      foreach my $try ( sort { length $b cmp length $a } keys %$map ) {
        if ( $s =~ /^$try/i ) {
          $transliterated .= $map->{$try};
          $s =~ s/^$try//i;
          next LETTER;
        }
      }
      $transliterated .= substr($s,0,1);
      $s = substr($s,1);
    }
    return $transliterated;
  },

  # Further wonky styles, which come from github.com/rjbs/misc/unicode-style,
  # are left up to wonkier people than me. -- rjbs, 2019-02-12
  script  => _wonky_style('script'),
  fraktur => _wonky_style('fraktur'),
  sans    => _wonky_style('ss'),
);

sub _wonky_style ($style) {
  my $i = 0;
  my %digit = map { $i++ => $_ }
    qw(ZERO ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT NINE);

  my $type = $style eq 'bold'    ? 'MATHEMATICAL BOLD'
           : $style eq 'script'  ? 'MATHEMATICAL BOLD SCRIPT'
           : $style eq 'fraktur' ? 'MATHEMATICAL FRAKTUR'
           : $style eq 'italic'  ? 'MATHEMATICAL ITALIC'
           : $style eq 'ss'      ? 'MATHEMATICAL SANS-SERIF'
           : $style eq 'sc'      ? 'LATIN LETTER SMALL'
           : $style eq 'ssb'     ? 'MATHEMATICAL SANS-SERIF BOLD'
           : $style eq 'ssi'     ? 'MATHEMATICAL SANS-SERIF ITALIC'
           : $style eq 'ssbi'    ? 'MATHEMATICAL SANS-SERIF BOLD ITALIC'
           : $style eq 'fw'      ? 'FULLWIDTH LATIN'
           : die "unknown type: $style";

  return sub ($str) {
    if ($style eq 'sc') {
      $str =~ s<([a-z])><
        my $name = $1 ge 'a' && $1 le 'z' ? "$type CAPITAL \U$1" : undef;
        $name ? charnames::string_vianame($name) // $1 : $1;
      >ge;
    } else {
      $str =~ s<([a-z0-9])><
        my $name = $1 ge 'a' && $1 le 'z' ? "$type SMALL \U$1"
                 : $1 ge 'A' && $1 le 'Z' ? "$type CAPITAL $1"
                 : $1 ge '0' && $1 le '9' ? "MATHEMATICAL BOLD DIGIT $digit{$1}"
                 : undef;
        $name =~ s/ (.)$/ LETTER $1/ if $style eq 'fw';
        $name ? charnames::string_vianame($name) // $1 : $1;
      >gei;
    }

    return $str;
  };
}

sub known_alphabets {
  map {; ucfirst } keys %Trans;
}

sub transliterate ($alphabet, $str) {
  return $str unless exists $Trans{lc $alphabet};
  return $Trans{lc $alphabet}->($str);
}

1;
