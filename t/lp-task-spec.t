#!perl
use v5.24.0;
use warnings;

use lib 'lib';
use utf8;

use Test::More;
use Test::Deep;

use Net::EmptyPort qw(empty_port);
use Path::Tiny ();
use Synergy::Logger::Test '$Logger';
use Synergy::Hub;

my $tmpfile = Path::Tiny->tempfile;
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users-lp.yaml",
    server_port => empty_port(),
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

        urgent_package_id => 2,
        inbox_package_id => 3,
        recurring_package_id => 4,

        project_portfolio_id => 5,

        interrupts_package_id => 6,

        primary_nag_channel_name => "test-channel",
      },
    },
    state_dbfile => "$tmpfile",
  }
);

for my $to_set (
  [ jetta => { lp => { 'default-project-shortcut' => 'pies' } } ],
  [ riot  => { lp => { 'default-project-shortcut' => 'gorp' } } ],
  [ roxy  => { user => { 'nicknames' => [ 'roxanne' ] } } ],
) {
  my ($username, $prefs) = @$to_set;

  my $user = $synergy->user_directory->user_named($username);

  for my $component_name (keys %$prefs) {
    my $component = $synergy->component_named($component_name);
    for my $pref (keys $prefs->{$component_name}->%*) {
      my $value = $prefs->{$component_name}{$pref};
      $component->set_user_preference($user, $pref, $value);
    }
  }
}

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
    conversation_address => 'stormer',
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
  "Eat more pie #pies are",
  {
    name        => "Eat more pie #pies are",
  },
  "text with a pound sign"
);

plan_ok(
  "Eat more pie#pies",
  {
    name        => "Eat more pie#pies",
  },
  "text and a project"
);

plan_ok(
  "Buy raisins ⏳ #GORP (!!!)",
  {
    name        => "Buy raisins",
    package_id  => 2,
    project_id  => 1,
    start       => 1,
  },
  "text, project, emoji, stuff"
);

plan_ok(
  "Buy raisins ⏳ #GORP (!!!)\n\nIf you're in Australia, buy sultanas.",
  {
    name        => "Buy raisins",
    package_id  => 2,
    project_id  => 1,
    start       => 1,
    description => "If you're in Australia, buy sultanas."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "lots of old-style flags, plus a description"
);

plan_ok(
  "Eat more pie #pies\n/assign roxy\n/go /urgent\n/e 5m-2\nOnly pumpkin, please.",
  {
    name        => "Eat more pie",
    start       => 1,
    package_id  => 2,
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

for my $pair ([ riot => 'gorp' ], [ jetta => 'pies' ]) {
  my ($username, $tag) = @$pair;

  plan_ok(
    {
      text => "Eat more pie",
      usernames => [ $username ],
    },
    {
      name    => "Eat more pie",
      tags    => { $tag => 1 },
      owners  => [ methods(username => $username) ],
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
    tags        => { gorp => 1, pies => 1 },
    owners      => bag(
      methods(username => 'jetta'),
      methods(username => 'riot'),
    )
  },
  "use all tags for multiple users"
);

plan_ok(
  {
    text => "Eat more pie #gorp",
    usernames => [ 'jetta' ],
  },
  {
    name        => "Eat more pie",
    project_id  => 1,
    tags        => { pies => 1 },
    owners      => [ methods(username => 'jetta') ],
  },
  "explicit project overrides user default"
);

plan_ok(
  "Eat more pie #pies --- /assign roxy --- /go /urgent --- /e 5m-2 --- Only pumpkin, please.",
  {
    name        => "Eat more pie",
    package_id  => 2,
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

plan_ok(
  "Eat more pie\n/assign roxy stormer",
  {
    name        => "Eat more pie",
    owners      => bag(
      methods(username => 'roxy'),
      methods(username => 'stormer'),
    ),
  },
  "multi-user /assign"
);

plan_ok(
  "Eat more pie\nThis is paragraph 1.\n\nThis is paragraph 2.",
  {
    name        => "Eat more pie",
    description => "This is paragraph 1.\n\nThis is paragraph 2."
                .  "\n\ncreated by Synergy in response to (some test event)",
  },
  "blank lines in long description are preserved"
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search("foo"),
  [
    { field => 'name', op => 'contains', value => 'foo' },
  ],
  'one-word search',
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search("foo done:1 bar"),
  [
    { field => 'name', op => 'contains', value => 'foo' },
    { field => 'done',                   value => '1'   },
    { field => 'name', op => 'contains', value => 'bar' },
  ],
  'simple search',
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search(q{^"Feature \\"requests\\""}),
  [
    { field => 'name', op => 'starts_with', value => 'Feature "requests"' },
  ],
  'search with prefix and qstring',
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search("foo done:1 type:*"),
  [
    { field => 'name', op => 'contains', value => 'foo' },
    { field => 'done',                    value => '1'   },
    { field => 'type',                    value => '*'   },
  ],
  'simple search with type:*',
);

TODO: {
  local $TODO = "tests not rewritten for new zip-based tags";

  is_deeply(
    $synergy->reactor_named('lp')->_parse_search("foo done:1 in:#tx"),
    [
      { field => 'name',  op => 'contains', value => 'foo' },
      { field => 'done',                    value => '1'   },
      { field => 'in',                      value => '#tx' },
    ],
    'simple search with type:*',
  );

  is_deeply(
    $synergy->reactor_named('lp')->_parse_search(q{#tx bar}),
    [
      { field => 'tags',                      value => 'topicbox' },
      { field => 'name',    op => 'contains', value => 'bar' },
    ],
    "leading with #shortcut",
  );
}

for my $u ("user:bar", "u:bar", "o:bar", "owner:bar") {
  is_deeply(
    $synergy->reactor_named('lp')->_parse_search("foo $u"),
    [
      { field => 'name',  op => 'contains', value => 'foo' },
      { field => 'owner',                   value => 'bar' },
    ],
    "owner specified as '$u'",
  );
}

is_deeply(
  $synergy->reactor_named('lp')->_parse_search(q{project:"JR \\"Bob\\" Dobbs" bob}),
  [
    { field => 'project',                   value => q{JR "Bob" Dobbs} },
    { field => 'name',    op => 'contains', value => 'bob' },
  ],
  "qstring in flag value",
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search(q{bar created:after:2019-01-01 foo}),
  [
    { field => 'name',    op => 'contains', value => 'bar' },
    { field => 'created', op => 'after',    value => '2019-01-01' },
    { field => 'name',    op => 'contains', value => 'foo' },
  ],
  "field:op:value for created:after:YYYY-MM-DD",
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search(q{bar created:after:"2019-02-02" foo}),
  [
    { field => 'name',    op => 'contains', value => 'bar' },
    { field => 'created', op => 'after',    value => '2019-02-02' },
    { field => 'name',    op => 'contains', value => 'foo' },
  ],
  "field:op:value with qstring value",
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search(q{bar created:after:“2019-02-02” foo}),
  [
    { field => 'name',    op => 'contains', value => 'bar' },
    { field => 'created', op => 'after',    value => '2019-02-02' },
    { field => 'name',    op => 'contains', value => 'foo' },
  ],
  "field:op:value with qstring value with smart quotes (good grief)",
);

is_deeply(
  $synergy->reactor_named('lp')->_parse_search(q{bar created:"after":"2019-02-02" foo}),
  [
    { field => 'name',    op => 'contains', value => 'bar' },
    { field => 'created', op => 'after',    value => '2019-02-02' },
    { field => 'name',    op => 'contains', value => 'foo' },
  ],
  "field:op:value with qstring value and qstring op",
);

done_testing;
