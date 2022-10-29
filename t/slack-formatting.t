#!perl
use v5.34.0;
use warnings;

use lib 'lib';

use Test::More;

use Synergy::Channel::Slack;

subtest "Url formatting" => sub {
  for my $pair (
    [
      "<http://test.com> <http://bar.com|bar.com>",
      "http://test.com bar.com",
    ],
    [
      "<http://test.com|test.com> <http://bar.com|bar.com>",
      "test.com bar.com"
    ],
    [
      "<http://test.com|test.com> <http://bar.com>",
      "test.com http://bar.com"
    ],
    [
      "Pre: <http://test.com> <http://bar.com|bar.com>",
      "Pre: http://test.com bar.com"
    ],
    [
      "<http://test.com> <http://bar.com|bar.com> Post",
      "http://test.com bar.com Post",
    ],
    [
      "foo",
      "foo",
    ],
    [
      "<> < >",
      "",
    ],
  ) {
    my ($pre, $expect) = @$pair;

    is(
      Synergy::Channel::Slack->decode_slack_formatting($pre),
      $expect,
      "$pre decoded properly"
    );
  }
};

done_testing;
