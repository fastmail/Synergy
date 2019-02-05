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

{
  my $B = "\N{REVERSE SOLIDUS}";

  my ($switches, $error) = parse_switches(qq{/foo "bar $B/baz" /buz});

  is($error, undef, 'no error');

  is_deeply(
    $switches,
    [
      [ foo => "bar $B/baz" ],
      [ buz => undef        ],
    ],
    "quotes",
  );
}

{
  my $B = "\N{REVERSE SOLIDUS}";

  my ($switches, $error) = parse_switches(qq{/foo hunter/killer program /buz});

  is($error, undef, 'no error');

  is_deeply(
    $switches,
    [
      [ foo => "hunter/killer program" ],
      [ buz => undef                   ],
    ],
    "quotes",
  );
}

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
    "canonicalize_switches",
  );
}

{
  my ($switches, $error) = parse_switches(q{/f \\"b\\" /foo /bar "some thing" /baz "some \\" /thing\\"" /meh a/b});

  is($error, undef, 'no error');

  is_deeply(
    $switches,
    [
      [ f   => '"b"'              ],
      [ foo => undef              ],
      [ bar => "some thing"       ],
      [ baz => "some \" /thing\"" ],
      [ meh => "a/b"              ],
    ],
    "quotes",
  );
}

done_testing;
