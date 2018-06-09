#!perl
use v5.24.0;
use warnings;

use lib 'lib';
use utf8;

use Test::More;
use Test::Deep;

use Synergy::Logger::Test '$Logger';
use Synergy::Hub;

my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users-lp.yaml",
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
        todo      => [ ],
      }
    },
    reactors => {
      lp => {
        class => 'Synergy::Reactor::LiquidPlanner',
        workspace_id => 1,
        primary_nag_channel_name => "test-channel",
      },
    }
  }
);

my $lp = $synergy->reactor_named('lp');

$lp->_set_projects({
  gorp => [ { id => 1, nickname => "GORP", name => "Eat More Gorp", } ],
  pies => [ { id => 2, nickname => "Pies", name => "Eat More Pies", } ],
});

sub plan_ok {
  my ($input, $expect, $desc) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $spec = ref $input ? $input : { text => $input };

  my $event = Synergy::Event->new({
    type => 'message',
    text => $spec->{text},
    from_address => 'stormer',
    from_user    => $synergy->user_directory->user_named('stormer'),
    from_channel => $synergy->channel_named('test-channel'),
    was_targeted => 1,
  });

  my ($plan) = $lp->task_plan_from_spec($event, $spec);

  cmp_deeply(
    $plan,
    {
      user        => methods(username => 'stormer'),
      description => "created by Synergy in response to (some test event)",
      %$expect,
    },
    $desc,
  ) or diag explain($plan);
}

plan_ok(
  "Eat more pie",
  { name => "Eat more pie" },
  "plain ol' text",
);

plan_ok(
  { text => "Eat more pie", usernames => [ qw(stormer) ] },
  { name => "Eat more pie", owners    => [ methods(username => 'stormer') ] },
  "plain ol' text, preassigned owners",
);

plan_ok(
  "Eat more pie #pies",
  {
    name        => "Eat more pie",
    project_id  => 2,
  },
  "text and a project"
);

plan_ok(
  "Buy raisins ⏳ #GORP (!!!)",
  {
    name        => "Buy raisins",
    project_id  => 1,
    running     => 1,
    urgent      => 1,
  },
  "text, project, emoji, stuff"
);

plan_ok(
  "Buy raisins ⏳ #GORP (!!!)\n\nIf you're in Australia, buy sultanas.",
  {
    name        => "Buy raisins",
    project_id  => 1,
    running     => 1,
    urgent      => 1,
    description => "If you're in Australia, buy sultanas."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "lots of old-style flags, plus a description"
);

done_testing;
