#!perl
use v5.24.0;
use warnings;
use utf8;

use experimental qw( signatures );

use lib 'lib';

use Test::More;

use Synergy::Logger::Test '$Logger';
use Synergy::Util qw(parse_switches canonicalize_switches);

sub switches_ok ($input, $want) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my @rv = parse_switches($input);

  my $ok = is_deeply(
    \@rv,
    [ $want, undef ],
    "$input -> OK",
  );

  diag explain [ @rv ] unless $ok;

  return $ok;
}

sub switches_fail ($input, $want) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  is_deeply(
    [ parse_switches($input) ],
    [ undef, $want ],
    "$input -> $want",
  );
}

switches_ok(
  "/foo bar /baz /buz",
  [
    [ foo => 'bar' ],
    [ baz => undef ],
    [ buz => undef ],
  ],
);

switches_ok(
  "/foo bar /foo /foo /foo baz",
  [
    [ foo => 'bar' ],
    [ foo => undef ],
    [ foo => undef ],
    [ foo => 'baz' ],
  ],
);

switches_fail(
  "foo /bar /baz /buz",
  "text with no switch",
);

my $B = "\N{REVERSE SOLIDUS}";

# Later, we will add support for qstrings. -- rjbs, 2019-02-04
switches_fail(
  qq{/foo "bar $B/baz" /buz},
  "incomprehensible input",
);

# Later, qstrings will allow embedded slashes, and maybe we'll allow them
# anyway if they're inside words.  For now, ban them. -- rjbs, 2019-02-04
switches_fail(
  qq{/foo hunter/killer program /buz},
  "incomprehensible input",
);

{
  my ($switches, $error) = parse_switches("/f b /b f /foo /bar /foo bar");
  canonicalize_switches($switches, { f => 'foo', b => 'bar' });

  is_deeply(
    $switches,
    [
      [ foo => 'b' ],
      [ bar => 'f' ],
      [ foo => undef ],
      [ bar => undef ],
      [ foo => 'bar' ],
    ],
  );
}

done_testing;
