use v5.28.0;
use warnings;

package Synergy::VestaUtil;

use experimental qw(signatures);
use utf8;

use MIME::Base64 ();

my %CHAR_FOR = (
  0 => "\N{IDEOGRAPHIC SPACE}",
  (map { $_ => chr(0xFF20 + $_) }      ( 1 .. 26)), # A .. Z
  (map { $_ => chr(0xFF10 + $_ - 26) } (27 .. 35)), # 1 .. 9
  36 => "\x{FF10}", # Zero

  40 => "\N{FULLWIDTH DOLLAR SIGN}",
  41 => "\N{FULLWIDTH LEFT PARENTHESIS}", # '(',
  42 => "\N{FULLWIDTH RIGHT PARENTHESIS}", # ')',

  44 => "\N{FULLWIDTH HYPHEN-MINUS}", # '-',

  46 => "\N{FULLWIDTH PLUS SIGN}", # '+',
  47 => "\N{FULLWIDTH AMPERSAND}", # '&',
  48 => "\N{FULLWIDTH EQUALS SIGN}", # '=',
  49 => "\N{FULLWIDTH SEMICOLON}", # ';',
  37 => "\N{FULLWIDTH EXCLAMATION MARK}", # '!',
  38 => "\N{FULLWIDTH COMMERCIAL AT}", # '@',
  39 => "\N{FULLWIDTH NUMBER SIGN}", # '#',
  50 => "\N{FULLWIDTH COLON}", # ':',

  52 => "\N{FULLWIDTH APOSTROPHE}", # "'",
  53 => "\N{FULLWIDTH QUOTATION MARK}",
  54 => "\N{FULLWIDTH PERCENT SIGN}",
  55 => "\N{FULLWIDTH COMMA}",
  56 => "\N{FULLWIDTH FULL STOP}",

  59 => "\N{FULLWIDTH SOLIDUS}",
  60 => "\N{FULLWIDTH QUOTATION MARK}",
  62 => "° ", # no full-width variant available

  # I don't think I should need a space after these, but I did in my
  # terminal?
  63 => '🟥',
  64 => '🟧',
  65 => '🟨',
  66 => '🟩',
  67 => '🟦',
  68 => '🟪',
  69 => '⬜️',
);

my %CODE_FOR = (
  ' ' => 0,
  (map {; $_ => ord($_) - 0x40 } ('A' .. 'Z')),
  '0' => 36,
  (map {; $_ => ord($_) - 0x16 } ( 1 ..   9 )),

  # If put into the qw[...], we'll get a warning, and this is simpler than
  # faffing about with "no warnings". -- rjbs, 2021-09-05
  '#' => 39,
  ',' => 55,

  '!' => 37,
  '@' => 38,
  '$' => 40,
  '(' => 41,
  ')' => 42,
  '-' => 44,
  '+' => 46,
  '&' => 47,
  '=' => 48,
  ';' => 49,
  ':' => 50,
  "'" => 52,
  '"' => 53,
  '%' => 54,
  '.' => 56,
  '/' => 59,
  '?' => 60,
  '°' => 62,

  '🟥' => 63,
  '🟧' => 64,
  '🟨' => 65,
  '🟩' => 66,
  '🟦' => 67,
  '🟪' => 68,
  '⬜' => 69,
);

sub board_to_text ($self, $characters) {
  my @lines;
  for my $line (@$characters) {
    push @lines,
      join q{}, map {; $CHAR_FOR{$_} // "\N{IDEOGRAPHIC SPACE}" } @$line;
  }

  return join qq{\n}, @lines;
}

sub encode_board {
  my ($self, $board) = @_;
  my $str = q{};
  my @queue = map {; @$_ } @$board;

  QUAD: while (defined(my $code = shift @queue)) {
    if (@queue >= 2 && $queue[0] == $code && $queue[1] == $code) {
      my $n = 3;
      splice @queue, 0, 2;

      while (@queue && $queue[0] == $code) {
        $n++;
        shift @queue;
      }

      $str .= chr($code | 128) . chr($n);

      next QUAD;
    }

    $str .= chr($code);
  }

  return MIME::Base64::encode_base64url($str);
}

sub _text_to_board ($self, $text) {
  # This will return either [...characters...] or a string that indicates what
  # went wrong.  This is stupid, but it's ... fine? -- rjbs, 2021-09-05
  $text = uc $text;

  $text =~ s/[‘’]/'/g; # Slack likes to smarten up quotes,
  $text =~ s/[“”]/"/g; # which is stupid. -- rjbs, 2021-08-12

  my @words = grep {; length } split /\s+/, $text;

  unless (@words) {
    return "There wasn't anything to post!";
  }

  my %unknown;
  for (@words) {
    $_ = [ map {; $CODE_FOR{$_} // ($unknown{$_} = -1) } split //, $_ ];
  }

  if (%unknown) {
    my @chars = sort keys %unknown;
    return "I didn't know what to do with these: @chars";
  }

  my @lines = ([]);
  while (defined(my $word = shift @words)) {
    if ($lines[-1]->@* + @$word + 1 < 22) {
      push $lines[-1]->@*, ($lines[-1]->@* ? 0 : ()), @$word;
    } elsif (@lines == 6) {
      return "I can't make the text fit.";
    } else {
      push @lines, [ @$word ];
    }
  }

  # 1. for given lines, left and right pad
  my ($minpad) = 22 - (sort { $b <=> $a } map {; 0 + @$_ } @lines)[0];
  my $leftpad  = int($minpad / 2);
  unshift @$_, (0) x $leftpad for @lines;
  push @$_, (0) x (22 - @$_) for @lines;

  # 2. add blank lines at top and bottom
  my $addlines = 6 - @lines;
  my $back     = int($addlines / 2) + ($addlines % 2);

  @lines = (
    (map {; [ (0) x 22 ] } (1 .. $addlines - $back)),
    @lines,
    (map {; [ (0) x 22 ] } (1 .. $back)),
  );

  return \@lines;
}

sub text_to_board ($self, $text) {
  $text = uc $text;

  unless ($self->_text_is_valid($text)) {
    return (undef, "Sorry, I can't post that to the board.");
  }

  my $post = $self->_text_to_board($text);

  unless (ref $post) {
    return (undef, "Sorry, I can't post that to the board.  $post");
  }

  return $post;
}

sub _text_is_valid ($self, $text) {
  # This feels pretty thing. -- rjbs, 2021-05-31
  return if $text =~ m{[^ 0-9A-Z!@#\$\(\)\-\+&=;:'"%,./?°🟥🟧🟨🟩🟦🟪⬜️]};
  return if length $text > 6 * 22;
  return 1;
}

1;
