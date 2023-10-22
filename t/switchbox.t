use v5.32.0;
use warnings;

use experimental qw(signatures);

use Test::More;
use Test::Deep ':v1';

use Synergy::SwitchBox;
use String::Switches qw(parse_switches);

use lib 't/lib';
use Test::SwitchBox;

my $box = Test::SwitchBox->new({
  schema => {
    name  => { type => 'str', join => 1 },
    age   => { type => 'num' },
    cat   => { type => 'str', multi => 1 },
    cool  => { type => 'bool' },
  },
});

$box->switches_ok(
  "/name Aiden Baker /age 48 /cat Fido /cat Mew",
  {
    name  =>'Aiden Baker',
    age   => 48,
    cat   => [ 'Fido', 'Mew' ],
  },
  "basic test",
);

$box->switches_ok(
  "/name Fran",
  {
    name  =>'Fran',
    age   => undef,
    cat   => [],
  },
  "behavior with switches not given",
);

$box->errors_ok(
  "/name Dana Cassidy /age unknown /unexpected inquisition",
  {
    structs => [
      { switch => 'age',        type => 'value' },
      { switch => 'unexpected', type => 'unknown' },
    ],
  },
  "simple example with errors",
);

$box->errors_ok(
  "/age 17 /age unknown /age 19",
  {
    structs => [
      { switch => 'age', type => 'value' },
      { switch => 'age', type => 'multi' },
    ],
    sentences => [
      "These switches had invalid values: age.",
      "These switches can only be given once, but were given multiple times: age.",
    ],
  },
  "simple example with type errors, /age x3",
);

# It would probably be better to provide both "value" and "multi", but we short
# circuit once one switch tuple has a value error and this is probably good
# enough. -- rjbs, 2023-10-22
$box->errors_ok(
  "/age 17 unknown 19",
  {
    structs => [
      { switch => 'age', type => 'value' },
    ],
  },
  "simple example with type errors, /age with 3 values",
);

$box->errors_ok(
  "/age",
  {
    structs => [
      { switch => 'age', type => 'novalue' },
    ],
  },
  "non-bool switch with no value",
);

$box->switches_ok(
  "/cool",
  {
    cool => 1,
  },
  "bool switch with no value",
);

for my $true (qw( 1 true yes on )) {
  $box->switches_ok(
    "/cool $true",
    {
      cool => 1,
    },
    "bool switch with truthy value ($true)",
  );
}

done_testing;
