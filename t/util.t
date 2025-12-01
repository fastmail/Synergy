use v5.36.0;

use Test::Deep;
use Test::More;

use Synergy::Util qw(validate_days_of_week validate_business_hours);

sub deeply_ok ($have_arrayref, $want_ok, $desc) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  cmp_deeply($have_arrayref->[0], $want_ok, "$desc: ok as expected");
  is($have_arrayref->[1], undef, "$desc: no error");
}

sub deeply_err ($have_arrayref, $want_err, $desc) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  is($have_arrayref->[0], undef, "$desc: no 'ok' part");
  cmp_deeply($have_arrayref->[1], $want_err, "$desc: error as expected");
}

deeply_ok(
  [ validate_days_of_week("Mon, Tue") ],
  [ qw(mon tue) ],
  "two-day DOWs, commas",
);

deeply_ok(
  [ validate_days_of_week("Mon Tue") ],
  [ qw(mon tue) ],
  "two-day DOWs, spaces",
);

deeply_err(
  [ validate_days_of_week("Mon Gorf Tue") ],
  re(qr/day abbrev/), # lousy error message, really
  "bogus date in input",
);

done_testing;
