use v5.28.0;
use warnings;
package Synergy::Util;

use utf8;
use experimental qw(lexical_subs signatures);

use charnames ();
use Carp;
use DateTime;
use DateTime::Format::Natural;
use JSON::MaybeXS;
use List::Util qw(first any);
use Path::Tiny ();
use Synergy::Logger '$Logger';
use Time::Duration::Parse;
use Time::Duration;
use TOML;
use YAML::XS;

use Sub::Exporter -setup => [ qw(
  read_config_file

  bool_from_text
  parse_date_for_user
  parse_time_hunk
  pick_one

  expand_date_range

  parse_switches
  canonicalize_names

  parse_colonstrings

  known_alphabets
  transliterate

  validate_business_hours describe_business_hours
  day_name_from_abbr

  reformat_help
) ];

sub read_config_file ($filename) {
  my $reader  = $filename =~ /\.ya?ml\z/ ? sub { YAML::XS::LoadFile($_[0]) }
              : $filename =~ /\.json\z/  ? \&_slurp_json_file
              : $filename =~ /\.toml\z/  ? \&_slurp_toml_file
              : confess "don't know how to read config file $filename";

  return $reader->($filename),
}

sub _slurp_json_file ($filename) {
  my $file = Path::Tiny::path($filename);
  confess "config file does not exist" unless -e $file;
  my $json = $file->slurp_utf8;
  return JSON::MaybeXS->new->decode($json);
}

sub _slurp_toml_file ($filename) {
  my $file = Path::Tiny::path($filename);
  confess "config file does not exist" unless -e $file;
  my $toml = $file->slurp_utf8;
  my ($data, $err) = from_toml($toml);
  unless ($data) {
    die "Error parsing toml file $filename: $err\n";
  }
  return $data;
}

# Handles yes/no, y/n, 1/0, true/false, t/f, on/off
sub bool_from_text ($text) {
  return 1 if $text =~ /^(yes|y|true|t|1|on|nahyeah)$/in;
  return 0 if $text =~ /^(no|n|false|f|0|off|yeahnah)$/in;

  return (undef, "you can use yes/no, y/n, 1/0, true/false, t/f, on/off, or yeahnah/nahyeah");
}

sub parse_date_for_user ($str, $user, $allow_midnight = 0) {
  my $tz = $user ? $user->time_zone : 'America/New_York';

  my $format = $tz =~ m{\AAmerica/} ? 'm/d' : 'd/m';

  state %parser_for;
  $parser_for{$tz} //= DateTime::Format::Natural->new(
    prefer_future => 1,
    format        => $format,
    time_zone     => $tz,
  );

  my $dt = $parser_for{$tz}->parse_datetime($str);

  return undef unless $parser_for{$tz}->success;

  return $dt if $allow_midnight;

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

sub expand_date_range ($from, $to) {
  $from = $from->clone; # Sigh. -- rjbs, 2019-11-13

  my @dates;
  until ($from > $to) {
    push @dates, $from->clone;
    $from->add(days => 1);
  }

  return @dates;
}

# Even a quoted string can't contain control characters.  Get real.
our $qstring    = qr{[“"]( (?: \\["“”] | [^\pC"“”] )+ )[”"]}x;

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
    } elsif ($string =~ s{ \A / (\s* | $) }{}x) {
      return (undef, "bogus input: / with no command!");
    } elsif ($string =~ s{ \A $qstring (\s* | $)}{}x) {
      my $match = $1;
      push @tokens, [ lit => $match =~ s/\\(["“”])/$1/gr ];
      next;
    } elsif ($string =~ s{ \A (\S+) (\s* | $) }{}x) {
      my $token = $1;

      return (undef, "unquoted arguments may not contain slash")
        if $token =~ m{/};

      push @tokens, [ lit => $token ];
      next;
    }

    return (undef, "incomprehensible input");
  }

  my @switches;

  while (my $token = shift @tokens) {
    if ($token->[0] eq 'badcmd') {
      Carp::confess("unreachable code");
    }

    if ($token->[0] eq 'cmd') {
      push @switches, [ $token->[1] ];
      next;
    }

    if ($token->[0] eq 'lit') {
      return (undef, "text with no switch") unless @switches;
      push $switches[-1]->@*, $token->[1];
      next;
    }

    Carp::confess("unreachable code");
  }

  return (\@switches, undef);
}

sub canonicalize_names ($hunks, $aliases = {}) {
  $_->[0] = $aliases->{ fc $_->[0] } // fc $_->[0] for @$hunks;
  return;
}

our $ident_re = qr{[-a-zA-Z][-_a-zA-Z0-9]*};

sub parse_colonstrings ($text, $arg) {
  my @hunks;

  state $switch_re = qr{
    \A
    ($ident_re)
    (
      (?: : (?: $qstring | [^\s:"“”]+ ))+
    )
    (?: \s | \z )
  }x;

  my $last = q{};
  TOKEN: while (length $text) {
    $text =~ s/^\s+//;

    # Abort!  Shouldn't happen. -- rjbs, 2018-06-30
    return undef if $last eq $text;

    $last = $text;

    if ($text =~ s/$switch_re//) {
      my @hunk = ($1);
      my $rest = $2;

      while ($rest =~ s{\A : (?: $qstring | ([^\s:"“”]+) ) }{}x) {
        push @hunk, length $1 ? ($1 =~ s/\\(["“”])/$1/gr) : $2;
      }

      push @hunks, \@hunk;

      next TOKEN;
    }

    push @hunks, $arg->{fallback}->(\$text) if $arg->{fallback};
  }

  return \@hunks;
}

my %MORSE_FOR = do {
  no warnings 'qw';
  (
    ' ' => '  ',
    qw(
      .     .-.-.-
      ,     --..--
      :     ---...
      ?     ..--..
      '     .----.
      -     -....-
      ;     -.-.-
      /     -..-.
      (     -.--.
      )     -.--.-
      "     .-..-.
      _     ..--.-
      =     -...-
      +     .-.-.
      !     -.-.--
      @     .--.-.
      A     .-
      B     -...
      C     -.-.
      D     -..
      E     .
      F     ..-.
      G     --.
      H     ....
      I     ..
      J     .---
      K     -.-
      L     .-..
      M     --
      N     -.
      O     ---
      P     .--.
      Q     --.-
      R     .-.
      S     ...
      T     -
      U     ..-
      V     ...-
      W     .--
      X     -..-
      Y     -.--
      Z     --..
      0     -----
      1     .----
      2     ..---
      3     ...--
      4     ....-
      5     .....
      6     -....
      7     --...
      8     ---..
      9     ----.
    )
  );
};

my %Trans;

sub _load_alphabets {
  return if keys %Trans;  # already done

  %Trans = (
    latin => sub ($s) { $s },
    rot13 => sub ($s) { $s =~ tr/A-Za-z/N-ZA-Mn-za-m/; $s },
    morse => sub ($s) {
      $s =~ s/\s+/ /g;

      my @cps = split //, $s;
      join q{ }, map {; exists $MORSE_FOR{uc $_} ? $MORSE_FOR{ uc $_} : $_ } @cps;
    },
    alexandrian => sub ($s) {
      my %letter = qw(
        a Σ     b h     c /     d ﻝ     e Ф
        f Ŧ     g ߔ     h b     i 𝑜     j i
        k ✓     l _     m ㇵ    n ߣ     o □
        p Г     q ᒣ     r w     s |     t Δ
        u ゝ    v ˧     w +     x ⌿     y A
        z ∞
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
    double  => _wonky_style('double'),
  );

  eval "require Acme::Zalgo";
  if ($@) {
    $Logger->log("ignoring Zalgo alphabet because Acme::Zalgo isn't installed");
  } else {
    $Trans{zalgo} = sub ($s) { Acme::Zalgo::zalgo($s, 0, 2, 0, 0, 0, 2); };
  }
}

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
           : $style eq 'double'  ? [ 'MATHEMATICAL DOUBLE-STRUCK', 'DOUBLE-STRUCK' ]
           : $style eq 'ssb'     ? 'MATHEMATICAL SANS-SERIF BOLD'
           : $style eq 'ssi'     ? 'MATHEMATICAL SANS-SERIF ITALIC'
           : $style eq 'ssbi'    ? 'MATHEMATICAL SANS-SERIF BOLD ITALIC'
           : $style eq 'fw'      ? 'FULLWIDTH LATIN'
           : die "unknown type: $style";

  my sub xlate ($c) {
    for my $t (ref $type ? @$type : $type) {
      my $name = $1 ge 'a' && $1 le 'z' ? "$t SMALL \U$1"
               : $1 ge 'A' && $1 le 'Z' ? "$t CAPITAL $1"
               : $1 ge '0' && $1 le '9' ? "MATHEMATICAL BOLD DIGIT $digit{$1}"
               : undef;

      $name =~ s/ (.)$/ LETTER $1/ if $style eq 'fw';
      my $c2 = charnames::string_vianame($name);
      return $c2 if $c2;
    }

    return $c;
  }

  return sub ($str) {
    if ($style eq 'sc') {
      $str =~ s<([a-z])><
        my $name = $1 ge 'a' && $1 le 'z' ? "$type CAPITAL \U$1" : undef;
        $name ? charnames::string_vianame($name) // $1 : $1;
      >ge;
    } else {
      $str =~ s<([a-z0-9])><xlate($1)>gei;
    }

    return $str;
  };
}

sub known_alphabets {
  _load_alphabets();
  map {; ucfirst } keys %Trans;
}

sub transliterate ($alphabet, $str) {
  _load_alphabets();
  return $str unless exists $Trans{lc $alphabet};
  return $Trans{lc $alphabet}->($str);
}

sub validate_business_hours ($value) {
  my $err = q{you can use "weekdays, 09:00-17:00" or "Mon: 09:00-17:00, Tue: 10:00-12:00, (etc.)"};

  my sub validate_start_end ($start, $end) {
    my ($start_h, $start_m) = split /:/, $start, 2;
    my ($end_h, $end_m) = split /:/, $end, 2;

    return undef if $end_h <= $start_h || $start_m >= 60 || $end_m >= 60;

    return {
      start => sprintf("%02d:%02d", $start_h, $start_m),
      end   => sprintf("%02d:%02d", $end_h, $end_m),
    };
  }

  if ($value =~ /^weekdays/i) {
    my ($start, $end) =
      $value =~ m{
        \Aweekdays,?
        \s+
        ([0-9]{1,2}:[0-9]{2})
        \s*
        (?:to|-)
        \s*
        ([0-9]{1,2}:[0-9]{2})
      }ix;

    return (undef, $err) unless $start && $end;

    my $struct = validate_start_end($start, $end);
    return (undef, $err) unless $struct;

    return {
      mon => $struct,
      tue => $struct,
      wed => $struct,
      thu => $struct,
      fri => $struct,
      sat => {},
      sun => {},
    };
  }

  my @hunks = split /,\s+/, $value;
  return (undef, $err) unless @hunks;

  my %week_struct = map {; $_ => {} } qw(mon tue wed thu fri sat sun);

  for my $hunk (@hunks) {
    my ($day, $start, $end) =
      $hunk =~ m{
        \A
        ([a-z]{3}):
        \s*
        ([0-9]{1,2}:[0-9]{2})
        \s*
        (?:to|-)
        \s*
        ([0-9]{1,2}:[0-9]{2})
      }ix;

    return (undef, $err) unless $day && $start && $end;
    return (undef, $err) unless $week_struct{ lc $day };

    my $day_struct = validate_start_end($start, $end);
    return (undef, $err) unless $day_struct;

    $week_struct{ lc $day } = $day_struct;
  }

  return \%week_struct;
}

sub describe_business_hours ($value, $user = undef) {
  my @wdays = qw(mon tue wed thu fri);
  my @wends = qw(sat sun);

  my %desc = map {; keys($value->{$_}->%*)
                    ? ($_ => "$value->{$_}{start}-$value->{$_}{end}")
                    : ($_ => '') } (@wdays, @wends);

  if ($user) {
    for my $dow (keys %desc) {
      $desc{$dow} .= $user->is_wfh_on($dow) ? " \N{HOUSE WITH GARDEN}" : '';
    }
  }

  return "None" unless any { length $_ } values %desc;

  if ($desc{mon} && 7 == grep {; $desc{$_} eq $desc{mon} } (@wdays, @wends)) {
    $desc{everyday} = $desc{mon};
    delete @desc{ @wdays };
    delete @desc{ @wends };
  }

  if ($desc{mon} && 5 == grep {; $desc{$_} eq $desc{mon} } @wdays) {
    $desc{weekdays} = $desc{mon};
    delete @desc{ @wdays };
  }

  if ($desc{sat} && 2 == grep {; $desc{$_} eq $desc{sat} } @wends) {
    $desc{weekends} = $desc{sat};
    delete @desc{ @wends };
  }

  return join q{, }, map {; $desc{$_} ? "\u$_: $desc{$_}" : () }
    (qw(weekdays sun), @wdays, qw(sat weekends));
}

sub day_name_from_abbr ($dow) {
  state $days = {
    mon => 'Monday',
    tue => 'Tuesday',
    wed => 'Wednesday',
    thu => 'Thursday',
    fri => 'Friday',
    sat => 'Saturday',
    sun => 'Sunday',
  };

  return $days->{$dow};
}

sub reformat_help ($string) {
  return $string =~ s/(\S)\n([^\s•])/$1 $2/rg;
}

1;
