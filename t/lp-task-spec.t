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

sub _r_ok {
  my ($n, $input, $expect, $desc) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 2;

  my $spec = ref $input ? $input : { text => $input };

  my $event = Synergy::Event->new({
    type => 'message',
    text => $spec->{text},
    from_address => 'stormer',
    from_user    => $synergy->user_directory->user_named('stormer'),
    from_channel => $synergy->channel_named('test-channel'),
    was_targeted => 1,
  });

  my @rv = $lp->task_plan_from_spec($event, $spec);

  cmp_deeply(
    $rv[$n],
    $expect,
    $desc,
  ) or diag explain(\@rv);
}

sub plan_ok  {
  my ($input, $expect, $desc) = @_;

  _r_ok(
    0,
    $input,
    {
      user        => methods(username => 'stormer'),
      description => "created by Synergy in response to (some test event)",
      %$expect,
    },
    $desc,
  );
}

sub error_ok {
  my ($input, $expect, $desc) = @_;

  _r_ok(
    1,
    $input,
    $expect,
    $desc,
  );
}

plan_ok(
  "Eat more pie",
  { name => "Eat more pie" },
  "plain ol' text",
);

plan_ok(
  { text => "Eat more pie", usernames => [ qw(roxanne) ] },
  { name => "Eat more pie", owners    => [ methods(username => 'roxy') ] },
  "plain ol' text, preassigned owners",
);

error_ok(
  { text => "Eat more pie", usernames => [ qw(roxanne Thing1 Thing2) ] },
  { usernames => "I don't know who Thing1 or Thing2 are." },
  "usernames we can't resolve",
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
    start       => 1,
    urgent      => 1,
  },
  "text, project, emoji, stuff"
);

plan_ok(
  "Buy raisins ⏳ #GORP (!!!)\n\nIf you're in Australia, buy sultanas.",
  {
    name        => "Buy raisins",
    project_id  => 1,
    start       => 1,
    urgent      => 1,
    description => "If you're in Australia, buy sultanas."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "lots of old-style flags, plus a description"
);

plan_ok(
  "Eat more pie #pies\n/assign roxy\n/go /urgent\n/e 5m-2\nOnly pumpkin, please.",
  {
    name        => "Eat more pie",
    urgent      => 1,
    start       => 1,
    project_id  => 2,
    owners      => [ methods(username => 'roxy') ],
    estimate    => { low => 3/36, high => 2 },
    description => "Only pumpkin, please."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "some slash commands"
);

plan_ok(
  "Eat more pie #pies\n/project pies",
  {
    name        => "Eat more pie",
    project_id  => 2,
  },
  "two project assignments to the same project: okay"
);

error_ok(
  "Eat more pie #pies\n/project gorp",
  {
    project => 'More than one project specified!',
  },
  "tried to assign two different projects"
);

plan_ok(
  "Eat more pie #pies\n/e .5",
  {
    name        => "Eat more pie",
    project_id  => 2,
    estimate    => { low => 0.5, high => 0.5 },
  },
  "/estimate with only one number"
);

for my $pair ([ riot => 1 ], [ jetta => 2 ]) {
  my ($username, $p_id) = @$pair;

  plan_ok(
    {
      text => "Eat more pie",
      usernames => [ $username ],
    },
    {
      name        => "Eat more pie",
      project_id  => $p_id,
      owners      => [ methods(username => $username) ],
    },
    "project id from a user's default project ($username)"
  );
}

plan_ok(
  {
    text => "Eat more pie\n/assign riot",
    usernames => [ qw(jetta) ],
  },
  {
    name        => "Eat more pie",
    owners      => bag(
      methods(username => 'jetta'),
      methods(username => 'riot'),
    )
  },
  "when users have conflicting default projects, choose none"
);

plan_ok(
  {
    text => "Eat more pie #gorp",
    usernames => [ 'jetta' ],
  },
  {
    name        => "Eat more pie",
    project_id  => 1,
    owners      => [ methods(username => 'jetta') ],
  },
  "explicit project overrides user default"
);

plan_ok(
  "Eat more pie #pies --- /assign roxy --- /go /urgent --- /e 5m-2 --- Only pumpkin, please.",
  {
    name        => "Eat more pie",
    urgent      => 1,
    start       => 1,
    project_id  => 2,
    owners      => [ methods(username => 'roxy') ],
    estimate    => { low => 3/36, high => 2 },
    description => "Only pumpkin, please."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "some slash commands, except with ---"
);

plan_ok(
  "Eat more pie --- Only pumpkin, please.",
  {
    name        => "Eat more pie",
    description => "Only pumpkin, please."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "plain ol' ---"
);

plan_ok(
  "Eat more pie \\--- Only pumpkin, please. --- /e 1-2",
  {
    name        => "Eat more pie --- Only pumpkin, please.",
    description => "created by Synergy in response to (some test event)",
    estimate    => { low => 1, high => 2 },
  },
  "plain ol' --- except with a backwhack"
);

done_testing;
