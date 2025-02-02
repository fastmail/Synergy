use v5.36.0;

use Synergy::Reactor::Todo;
use Test::More;

my $desc = <<~'SNOVEL';
  Looks, there are many reasons that I could do the snoveling, but the best one is that snoveling is hard, and doing hard things is always worthwhile.

  Right?
  SNOVEL

my ($uid, $ical) = Synergy::Reactor::Todo->_make_icalendar(
  "do some snoveling",
  {
    DESCRIPTION => $desc,
    PRIORITY    => 1,
  },
);

my @lines = split /\n/, $ical;

ok(
  (! grep {; $_ eq "DESCRIPTION:$desc" } @lines),
  "description is not in ical, probably folder",
);

# Perform ungarbling...
{
  # Unfold
  for my $i (reverse 1 .. $#lines) {
    next unless $lines[$i] =~ s/^ //;
    $lines[$i - 1] .= $lines[$i];
    splice @lines, $i, 1;
  }

  # Decode
  $_ = Encode::decode('UTF-8', $_) for @lines;

  # Undo newline munging
  s/\N{LINE SEPARATOR}/\n/g for @lines;
}

ok(
  (grep {; $_ eq "DESCRIPTION:$desc" } @lines),
  "unfolded ical has description properly",
);

done_testing;
