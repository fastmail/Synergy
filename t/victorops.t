#!perl
use v5.24.0;
use warnings;
use experimental 'signatures';

use lib 'lib', 't/lib';

use Future;
use IO::Async::Test;
use JSON::MaybeXS qw(encode_json decode_json);
use Plack::Request;
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
      alert_endpoint_uri => '',   # rewritten later
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

# prefs
my $vo = $s->reactor_named('vo');
for my $who (qw(alice bob)) {
  my $user = $s->user_directory->user_named($who);
  $vo->set_user_preference($user, 'username', $who);
}

# Fake up responses from VO.
my @VO_RESPONSES;
my $VO_RESPONSE = gen_response(200, {});
$s->server->register_path('/vo', sub ($env) {
  if (@VO_RESPONSES) {
    my $next = shift @VO_RESPONSES;

    if (ref $next eq 'CODE') {
      my $req = Plack::Request->new($env);
      return $next->($req);
    }

    return $next;
  }

  return $VO_RESPONSE;
});

my $ALERT_RESPONSE = gen_response(200, {});
$s->server->register_path('/alerts', sub ($env) { return $ALERT_RESPONSE });

my $api_url   = sprintf("http://localhost:%s/vo", $s->server->server_port);
my $alert_url = sprintf("http://localhost:%s/alerts", $s->server->server_port);

# Muck with the guts of VO reactor to catch our fakes.
my $endpoint = Sub::Override->new(
  'Synergy::Reactor::VictorOps::_vo_api_endpoint',
  sub { return $api_url },
);

my $alert_endpoint = Sub::Override->new(
  'Synergy::Reactor::VictorOps::alert_endpoint_uri',
  sub { return $alert_url },
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

sub multiple_message_text($num, $index) {
  my @texts = map {; $_->{text} } $channel->sent_messages;
  fail("expected $num messages, but got " . @texts) if @texts != $num;
  $channel->clear_messages;
  return $texts[$index];
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

# We want to test, for our PATCH requests, that we only request the ones we
# expect. So here, we return as many successful results as there were
# incidents. Later, if we make the assertions in the VO reactor stronger
# (rather than just returning a count of the results without checking their
# content), this will be easier to extend.
my $patch_responder = sub ($req) {
  note("got JSON data: " . $req->content);
  my $patch_data = decode_json($req->content);

  my @incidents = $patch_data->{incidentNames}->@*;

  return gen_response(200, { results => \@incidents });
};

subtest 'exit maint' => sub {
  # not in maint
  $VO_RESPONSE = gen_response(200, { activeInstances => [] });

  send_message('synergy: demaint', 'alice');
  like(
    single_message_text(),
    qr{not in maint right now}i,
    'get a warning from trying to demaint when not there'
  );

  # first response for "yeah we're in maint," second for successful demaint
  @VO_RESPONSES = (
    gen_response(200, { activeInstances => [{ isGlobal => 1, instanceId => 42 }] }),
    gen_response(200, {}),
  );

  send_message('synergy: demaint', 'alice');
  like(
    single_message_text(),
    qr{maint cleared}i,
    'successful demaint from a mainted state'
  );

  # first response for "yeah we're in maint," second for successful demaint
  @VO_RESPONSES = (
    gen_response(200, { activeInstances => [{ isGlobal => 1, instanceId => 42 }] }),
    gen_response(400, {}),
  );

  send_message('synergy: demaint', 'alice');
  like(
    single_message_text(),
    qr{couldn't clear the VO maint}i,
    'reasonable error on demaint failure'
  );

  # exit maint and /resolve
  # 55, 56 should resolve
  # 42, 43 predate maint startedAt
    my $incidents = {
    incidents => [
      {
        incidentNumber => 69,
        currentPhase => 'UNACKED',
        startTime => '1970-01-01T00:00:10Z',
      },
      {
        incidentNumber => 79,
        currentPhase => 'ACKED',
        startTime => '1970-01-01T00:00:11Z',
      },
      {
        incidentNumber => 89,
        currentPhase => 'UNACKED',
        startTime => '1970-01-02T00:54:11Z',
      },
      {
        incidentNumber => 99,
        currentPhase => 'ACKED',
        startTime => '1970-01-02T00:54:11Z',
      },
      {
        incidentNumber => 109,
        currentPhase => 'RESOLVED',
        startTime => '1971-01-02T00:54:11Z',
      }
    ],
  };

  @VO_RESPONSES = (
    gen_response(200, { activeInstances => [{ isGlobal => 1, instanceId => 42, startedAt => 86400 }] }),
    gen_response(200, {}),
    gen_response(200, $incidents),
    $patch_responder,
  );

    send_message('synergy: demaint /resolve', 'alice');
    like(
      multiple_message_text(2, 0),
      qr{Successfully resolved 2 incidents. The board is clear!}i,
      'demaint /resolve'
    );
};

subtest 'ack all' => sub {
  my $incidents = {
    incidents => [
      {
        incidentNumber => 42,
        currentPhase => 'UNACKED',
      },
      {
        incidentNumber => 37,
        currentPhase => 'RESOLVED',
      }
    ],
  };

  # list of incidents, successful ack
  @VO_RESPONSES = (
    gen_response(200, $incidents),
    $patch_responder,
  );

  send_message('synergy: ack all');
  like(
    single_message_text(),
    qr{acked 1 incident},
    'successful ack all, n = 1'
  );

  # two incidents
  $incidents->{incidents}[1]{currentPhase} = 'UNACKED';
  @VO_RESPONSES = (
    gen_response(200, $incidents),
    $patch_responder,
  );

  send_message('synergy: ack all');
  like(
    single_message_text(),
    qr{acked 2 incidents},
    'successful ack all, n > 1'
  );

  # failed ack
  @VO_RESPONSES = (
    gen_response(200, $incidents),
    gen_response(500, {}),
  );

  send_message('synergy: ack all');
  like(
    single_message_text(),
    qr{Something went wrong acking incidents},
    'on a failed ack, we get a reasonable error'
  );
};

subtest 'resolve' => sub {
  my $incidents = {
    incidents => [
      {
        incidentNumber => 42,
        currentPhase => 'ACKED',
        transitions => [{ by => 'alice' }],
      },
      {
        incidentNumber => 37,
        currentPhase => 'ACKED',
        transitions => [{ by => 'bob' }],
      }
    ],
  };

  # For a patch, we want to return only the number of results actually
  # requested.
  my $patch_responder = sub ($req) {
    note("got JSON data: " . $req->content);
    my $patch_data = decode_json($req->content);
    my @incidents = $patch_data->{incidentNames}->@*;
    return gen_response(200, { results => \@incidents });
  };

  @VO_RESPONSES = (
    gen_response(200, $incidents),
    $patch_responder,
  );

  send_message('synergy: resolve all');
  like(
    single_message_text(),
    qr{resolved 2 incidents},
    'we successfully patched and resolved all acked'
  );

  @VO_RESPONSES = (
    gen_response(200, $incidents),
    $patch_responder,
  );

  send_message('synergy: resolve mine');
  like(
    single_message_text(),
    qr{resolved 1 incident},
    'we successfully patched and resolved our own acked'
  );
};

subtest 'alert' => sub {
  send_message('synergy: alert the toast is on fire');
  like(
    single_message_text(),
    qr{sent the alert\.\s+Good luck},
    'successful alert send'
  );

  $ALERT_RESPONSE = gen_response(403, {});

  send_message('synergy: alert the toast is on fire');
  like(
    single_message_text(),
    qr{couldn't send this alert},
    'good message on failed send'
  );
};

done_testing;
