package Synergy::TextThemer;

### This whole thing is a hack and a WIP and I'd like to write something cool
### and better, but for now I just need a way to encapsulate this so it isn't
### cluttering up the Console channel and diagnostic interface code.
###                                                       -- rjbs, 2022-01-08

use v5.32.0;
use Moose;

use experimental qw(signatures);
use utf8;

use Term::ANSIColor qw(colored);

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

    if ($closed && length $line <= 76) {
      $new_text .= sprintf '%-76s', $line;
      $new_text .= "$line_C$B_ver" if length $line <= 76;
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

sub _format_message_compact ($self, $name, $address, $text) {
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

sub _format_message_chonky ($self, $name, $address, $text) {
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

  my $dest_width = length "$name/$address";

  my $dest = "$text_C$name$line_C!$text_C$address$line_C";

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

1;
