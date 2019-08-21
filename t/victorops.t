#!perl
use v5.24.0;
use warnings;
use experimental 'signatures';

use lib 'lib', 't/lib';

use Future;
use IO::Async::Test;
use JSON::MaybeXS qw(encode_json);
use Plack::Response;
use Sub::Override;
use Test::More;

use Synergy::Logger::Test '$Logger';
use Synergy::Reactor::VictorOps;
use Synergy::Tester;

# I'm not actually using this to do any testing, but it's convenient to set up
# users.
my $result = Synergy::Tester->testergize({
  reactors => {
    vo => {
      class              => 'Synergy::Reactor::VictorOps',
      alert_endpoint_uri => '',
      api_id             => '1234',
      api_key            => 'secrets',
      team_name          => 'plumbing',
    },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
    bob => undef,
  },
  todo => [],
});

# Set up a bunch of nonsense
local $Logger = $result->logger;
my $s = $result->synergy;
my $channel = $s->channel_named('test-channel');

# Fake up responses from VO.
my $VO_RESPONSE = gen_response(200, {});
$s->server->register_path('/vo', sub { $VO_RESPONSE });
my $url = sprintf("http://localhost:%s/vo", $s->server->server_port);

# Muck with the guts of VO reactor to catch our fakes.
my $endpoint = Sub::Override->new(
  'Synergy::Reactor::VictorOps::_vo_api_endpoint',
  sub { return $url },
);
my $oncall = Sub::Override->new(
  'Synergy::Reactor::VictorOps::_current_oncall_names',
  sub { return Future->done('alice') },
);

# dumb convenience methods
sub gen_response ($code, $data) {
  my $json = encode_json($data);
  return Plack::Response->new($code, [], $json)->finalize;
}

sub send_message ($text, $from = $channel->default_from) {
  $channel->queue_todo([ send => { text => $text, from => $from }  ]);
  $channel->queue_todo([ wait => {} ]);
  wait_for { $channel->is_exhausted; };
}

sub single_message_text {
  my @texts = map {; $_->{text} } $channel->sent_messages;
  fail("expected only one message, but got " . @texts) if @texts > 1;
  $channel->clear_messages;
  return $texts[0];
}

# ok, let's test.

subtest 'info' => sub {
  send_message('synergy: oncall');
  is(single_message_text(), 'current oncall: alice' , 'alice is oncall');

  # status, in maint
  $VO_RESPONSE = gen_response(200, { activeInstances => [] });
  send_message('synergy: maint status');
  like(single_message_text(), qr{everything is fine maybe}i, 'we are not in maint');
};

subtest "enter maint" => sub {
  $VO_RESPONSE = gen_response(200, {});   # from POST /maintenancemode

  # bob tries to put in maint, but is not oncall
  send_message('synergy: maint start', 'bob');
  like(
    single_message_text(),
    qr{try again with /force}i,
    'bob is not oncall, and cannot start maint without /force'
  );

  send_message('synergy: maint start', 'alice');
  like(
    single_message_text(),
    qr{now in maint}i,
    'alice is oncall, and can start maint'
  );

  send_message('synergy: maint start /force', 'bob');
  like(
    single_message_text(),
    qr{now in maint}i,
    'bob is not oncall, but can force the issue'
  );

  $VO_RESPONSE = gen_response(409, {});
  send_message('synergy: maint start', 'alice');
  like(
    single_message_text(),
    qr{already in maint}i,
    'get a warning from trying to maint when already there'
  );
};

done_testing;
