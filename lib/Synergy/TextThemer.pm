package Synergy::TextThemer;

### This whole thing is a hack and a WIP and I'd like to write something cool
### and better, but for now I just need a way to encapsulate this so it isn't
### cluttering up the Console channel and diagnostic interface code.
###                                                       -- rjbs, 2022-01-08

use v5.36.0;
use Moose;

use utf8;

use Digest::SHA ();
use Term::ANSIColor qw(colored);

my sub plainlength ($str) {
  length Term::ANSIColor::colorstrip($str);
}

my %THEME = (
  cyan    => { decoration_color =>   75,  text_color => 117 },
  green   => { decoration_color =>   10,  text_color =>  84 },
  purple  => { decoration_color =>  140,  text_color =>  13 },
  rwhite  => { decoration_color =>    9,  text_color =>  15 },
);

has decoration_color => (is => 'ro', isa => 'Int', required => 1);
has text_color       => (is => 'ro', isa => 'Int', required => 1);

has decoration_color_code => (
  is   => 'ro',
  lazy => 1,
  default => sub { Term::ANSIColor::color("ansi" . $_[0]->decoration_color) },
);

has text_color_code => (
  is   => 'ro',
  lazy => 1,
  default => sub { Term::ANSIColor::color("ansi" . $_[0]->text_color) },
);

sub is_null ($self) {
  return $self->decoration_color == -1 && $self->text_color == -1;
}

sub null_themer ($class) {
  $class->new({ decoration_color => -1, text_color => -1 });
}

sub from_name ($class, $name) {
  Carp::confess(qq{"$name" isn't a known theme}) unless $THEME{$name};

  return $class->new($THEME{$name});
}

sub _format_raw ($self, $thing) {
  return $thing;
}

sub _format_box ($self, $text, $title = undef) {
  $self->_format_generic_box($text, 1, $title);
}

sub _format_wide_box ($self, $text, $title = undef) {
  $self->_format_generic_box($text, 0, $title);
}

sub _format_generic_box ($self, $text, $closed, $title) {
  state $B_TL  = q{╔};
  state $B_BL  = q{╚};
  state $B_TR  = q{╗};
  state $B_BR  = q{╝};
  state $B_ver = q{║};
  state $B_hor = q{═};

  state $B_boxleft  = q{╣};
  state $B_boxright = q{╠};

  my $themed = ! $self->is_null;

  my $text_C = $themed ? $self->text_color_code          : q{};
  my $line_C = $themed ? $self->decoration_color_code    : q{};
  my $null_C = $themed ? Term::ANSIColor::color('reset') : q{};

  my $header = "$line_C$B_TL" . ($B_hor x 77) . "$B_TR$null_C\n";
  my $footer = "$line_C$B_BL" . ($B_hor x 77) . "$B_BR$null_C\n";

  if (length $title) {
    my $width = length $title;

    $header = "$line_C$B_TL"
            . ($B_hor x 5)
            . "$B_boxleft $title $B_boxright"
            . ($B_hor x (72 - $width - 4))
            . "$B_TR$null_C\n";
  }

  my $new_text = q{};
  for my $line (split /\n/, $text) {
    $new_text .= "$line_C$B_ver $text_C";

    state $CLEAR = Term::ANSIColor::color('reset');
    $line =~ s/\Q$CLEAR/$text_C/g;

    my $plainlength = plainlength($line);

    if ($closed && $plainlength <= 76) {
      $new_text .= $line . (q{ } x (76 - $plainlength));
      $new_text .= "$line_C$B_ver";
    } else {
      $new_text .= $line;
    }

    $new_text .= "$null_C\n";
  }

  return "$header$new_text$footer";
}

sub _format_notice ($self, $from, $text) {
  my $message;

  if ($self->is_null) {
    return $message = "⬮⬮ $from ⬮⬮ $text\n";
  }

  my $c0 = $self->decoration_color;
  my $c1 = $self->text_color;

  $message = colored([ "ansi$c0" ], "⬮⬮ ")
           . colored([ "ansi$c1" ], sprintf '%-s', $from)
           . colored([ "ansi$c0" ], " ⬮⬮ ")
           . colored([ "ansi$c1" ], $text)
           . "\n";

  return $message;
}

sub _format_message_compact ($self, $message) {
  my $address = $message->{address};
  my $name    = $message->{name};
  my $text    = $message->{text};

  return "❱❱ $name!$address ❱❱ $text\n" if $self->is_null;

  my $c0 = $self->decoration_color;
  my $c1 = $self->text_color;

  return colored([ "ansi$c0" ], "❱❱ ")
       . colored([ "ansi$c1" ], $name)
       . colored([ "ansi$c0" ], '!')
       . colored([ "ansi$c1" ], $address)
       . colored([ "ansi$c0" ], " ❱❱ ")
       . colored([ "ansi$c1" ], $text)
       . "\n";
}

sub _format_message_chonky ($self, $message) {
  my $address = $message->{address};
  my $name    = $message->{name};
  my $text    = $message->{text};

  state $B_TL  = q{╭};
  state $B_BL  = q{╰};
  state $B_TR  = q{╮};
  state $B_BR  = q{╯};
  state $B_ver = q{│};
  state $B_hor = q{─};

  state $B_boxleft  = q{┤};
  state $B_boxright = q{├};

  my $themed = ! $self->is_null;

  my $text_C = $themed ? $self->text_color_code          : q{};
  my $line_C = $themed ? $self->decoration_color_code    : q{};
  my $null_C = $themed ? Term::ANSIColor::color('reset') : q{};

  my $dest = "$text_C$name$line_C!$text_C$address$line_C";

  if (defined $message->{number}) {
    $dest .= " ${line_C}#$text_C$message->{number}";
  }

  my $dest_width = plainlength($dest);

  my $header = "$line_C$B_TL"
             . ($B_hor x 5)
             . "$B_boxleft $dest $B_boxright"
             . ($B_hor x (72 - $dest_width - 4))
             . "$B_TR$null_C\n";

  my $footer = "$line_C$B_BL" . ($B_hor x 77) . "$B_BR$null_C\n";

  my $new_text = q{};

  my @lines = split /\n/, $text;
  while (defined(my $line = shift @lines)) {
    $new_text .= "$line_C$B_ver $text_C";
    if (length $line > 76) {
      my ($old, $rest) = $line =~ /\A(.{1,76})\s+(.+)/;
      if (length $old) {
        $new_text .= $old;
        unshift @lines, $rest;
      } else {
        # Oh well, nothing to do about it!
        $new_text .= $line;
      }
    } else {
      $new_text .= $line;
    }
    $new_text .= "$null_C\n";
  }

  return "$header$new_text$footer";
}

sub _format ($self, $what) {
  unless (
       ref $what
    && ref $what eq 'ARRAY'
    && $what->[0]
    && $self->can("_format_$what->[0]")
  ) {
    return $self->_format_box(
      "Internal error!  Don't know how to display result.",
      "ERROR",
    );
  }

  my $method = "_format_$what->[0]";
  $self->$method($what->@[ 1 .. $what->$#* ]);
}

sub deterministic_color ($self, $str) {
  state $typ = ($ENV{COLORTERM}//'') eq 'truecolor' ? 256 : 6;
  state $mod = $typ == 256 ?  16 : 6;
  state $mul = $typ == 256 ?   8 : 1;
  state $min = $typ == 256 ? 512 : 6;
  state $inc = $typ == 256 ?  16 : 1;
  state $fmt = $typ == 256 ? 'r%ug%ub%u' : 'rgb%u%u%u';

  my $sha1 = Digest::SHA::sha1($str);
  my ($r, $g, $b, $i) = unpack 'SSSN', $sha1;
  $r = ($r % $mod) * $mul;
  $g = ($g % $mod) * $mul;
  $b = ($b % $mod) * $mul;

  while ($r + $g + $b < $min) {
    my $j = $i % 3;
    $i >>= 2;
    $r += $inc unless $j == 0 or $r >= $typ - $inc;
    $g += $inc unless $j == 1 or $g >= $typ - $inc;
    $b += $inc unless $j == 2 or $b >= $typ - $inc;
  }

  return sprintf $fmt, $r, $g, $b;
}

sub deterministic_colored ($self, $str, $as = undef) {
  require Term::ANSIColor;
  my $color = $self->deterministic_color($as // $str);
  return Term::ANSIColor::colored([ $color ], $str);
}

1;
