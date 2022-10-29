#!perl
use v5.34.0;
use warnings;
use experimental 'signatures';

use Test::More;
use Test::Deep;

use lib 't/lib';

use Synergy::Test::CommandPost;

subtest "the absolute basics" => sub {
  my $outpost = create_outpost(
    [ command => foo => {} => tail_echoer ],
  );

  my $plan = $outpost->consider_targeted("foo bar");

  $plan->cmp_potential(
    methods(name => 'command-foo', is_exclusive => 1),
    "command foo handles 'foo bar'",
  );

  $plan->cmp_results(
    {
      name    => 'command-foo',
      result  => [ 'bar' ],
    },
  );
};

subtest "aliases" => sub {
  my $outpost = create_outpost(
    [ command => foo => { aliases => [ qw(bar) ] } => tail_echoer ],
  );

  $outpost->consider_targeted("foo bar")->cmp_results(
    { name => 'command-foo', result  => [ 'bar' ] },
  );

  $outpost->consider_targeted("FOO bar")->cmp_results(
    { name => 'command-foo', result  => [ 'bar' ] },
    "commands match case insensitively, but args are not munged",
  );

  # Right now, the name of the reaction comes from the name that matched,
  # rather than the name under which the command was declared.  This isn't
  # really the kind of thing to guarantee, so we'll allow either one here.
  # (In a perfect world, I might always use the declared name, but it's not
  # worth the time to fiddle.) -- rjbs, 2022-01-15
  $outpost->consider_targeted("bar quux")->cmp_results(
    { name => any('command-bar', 'command-foo'), result  => [ 'quux' ] },
  );
};

subtest "matchers and parsers" => sub {
  my sub split_if_matching ($regex) {
    return sub ($text, @) {
      return unless $text =~ $regex;
      return [ split //, $text ];
    }
  }

  my $outpost = create_outpost(
    [ responder => demo => { matcher => split_if_matching(q{0}) } => tail_echoer ],
    [ command   => demo => { parser  => split_if_matching(q{9}) } => tail_echoer ],
  );

  $outpost->consider_targeted("gorp")->cmp_potential("we won't react without matches");

  $outpost->consider_targeted("g0rp")->cmp_results(
    { name => 'responder-demo', result => [ qw( g 0 r p ) ] },
    'matcher sub determines args to responder',
  );

  $outpost->consider_targeted("demo g9rp")->cmp_results(
    { name => 'command-demo', result => [ qw( g 9 r p ) ] },
    'parser sub determines args to command',
  );
};

done_testing;
