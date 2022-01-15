#!perl
use v5.28.0;
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

  $plan->cmp_prs(
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

subtest "matchers" => sub {
  my sub split_if_matching ($regex) {
    return sub ($event) {
      my $text = $event->text;
      return unless $text =~ $regex;
      return [ split //, $text ];
    }
  }

  my $outpost = create_outpost(
    [ reaction => demo => { matcher => split_if_matching(q{0}) } => tail_echoer ],
  );

  $outpost->consider_targeted("gorp")->cmp_prs("we won't react without matches");

  $outpost->consider_targeted("g0rp")->cmp_results(
    { name => 'reaction-demo', result => [ qw( g 0 r p ) ] },
    'matcher sub determines args to reaction',
  );
};

done_testing;
