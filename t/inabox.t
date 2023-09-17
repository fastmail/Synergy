use v5.32.0;
use warnings;
use experimental 'signatures';

use lib 'lib', 't/lib';

use Future;
use IO::Async::Test;
use JSON::MaybeXS qw(encode_json);
use Plack::Response;
use Sub::Override;
use Storable qw(dclone);
use Test::More;
use Test::Deep;

use Synergy::Logger::Test '$Logger';
use Synergy::Reactor::InABox;
use Synergy::Tester;

# I'm not actually using this to do any testing, but it's convenient to set up
# users.
my $result = Synergy::Tester->testergize({
  reactors => {
    inabox => {
      class                  => 'Synergy::Reactor::InABox',
      box_domain             => 'fm.local',
      vpn_config_file        => '',
      digitalocean_api_token => '1234',
      default_box_version    => 'bullseye',
      box_datacentres        => ['nyc3', 'sfo3'],
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
my @DO_RESPONSES;
my $DO_RESPONSE = gen_response(200, {});
$s->server->register_path(
  '/digital-ocean',
  sub {
    return shift @DO_RESPONSES if @DO_RESPONSES;
    return $DO_RESPONSE;
  },
  'test file',
);

my $url = sprintf("http://localhost:%s/digital-ocean", $s->server->server_port);

# Muck with the guts of Dobby to catch our fakes.
my $endpoint = Sub::Override->new(
  'Dobby::Client::api_base',
  sub { return $url },
);

# dumb convenience methods
sub gen_response ($code, $data) {
  my $json = encode_json($data);
  return Plack::Response->new($code, [], $json)->finalize;
}

sub send_message ($text, $from = $channel->default_from, $wait_arg = {}) {
  $channel->queue_todo([ send => { text => $text, from => $from }  ]);
  $channel->queue_todo([ wait => $wait_arg ]);
  wait_for { $channel->is_exhausted; };
}

sub single_message_text {
  my @texts = map {; $_->{text} } $channel->sent_messages;
  fail("expected only one message, but got " . @texts) if @texts > 1;
  $channel->clear_messages;
  return $texts[0];
}

# ok, let's test.

# minimal data for _format_droplet
my $alice_droplet = {
  id     => 123,
  name   => 'alice-bullseye.box.fm.local',
  status => 'active',
  image  => {
    name => 'fminabox-bullseye-20200202'
  },
  region => {
    name => 'Bridgewater',
    slug => 'bnj1',
  },
  networks => {
    v4 => [{
      ip_address => '127.0.0.2',
      type => 'public',
    }],
  },
};

subtest 'status' => sub {
  # alice has a box, bob has none
  $DO_RESPONSE = gen_response(200, { droplets => [ $alice_droplet ] });

  send_message('synergy: box status');
  like(
    single_message_text(),
    qr{Your boxes:\s+name: \Qalice-bullseye.box.fm.local\E},
    'alice has a box and synergy says so'
  );

  send_message('synergy: box status', 'bob');
  is(
    single_message_text(),
    "You don't seem to have any boxes.",
    'bob has no box and synergy says so'
  );
};

# the above has confirmed that we can talk to DO and get the box, so now we'll
# just fake that method up.
our $droplet_guard = Sub::Override->new(
  'Synergy::Reactor::InABox::_get_droplet_for',
  sub { return Future->done($alice_droplet) },
);

subtest 'poweron' => sub {
  # already on
  send_message('synergy: box poweron');
  is(
    single_message_text(),
    'That box is already powered on!',
    'if the box is already on, synergy says so'
  );

  # now off
  local $alice_droplet->{status} = 'off';
  @DO_RESPONSES = (
    gen_response(200, { action => { id => 987 } }),
    gen_response(200, { action => { status => 'completed'   } }),
  );

  send_message('synergy: box poweron');

  my @texts = map {; $_->{text} } $channel->sent_messages;
  is(@texts, 3, 'sent three messages (reactji on/off, and message)')
    or diag explain \@texts;

  is($texts[2], 'That box has been powered on.', 'successfully turned on');

  $channel->clear_messages;
};

for my $method (qw(poweroff shutdown)) {
  subtest $method => sub {
    @DO_RESPONSES = (
      gen_response(200, { action => { id => 987 } }),
      gen_response(200, { action => { status => 'completed' } }),
    );

    send_message("synergy: box $method");

    my @texts = map {; $_->{text} } $channel->sent_messages;
    is(@texts, 3, 'sent three messages (reactji on/off, and message)')
      or diag explain \@texts;

    like(
      $texts[2],
      qr{That box has been (powered off|shut down)},
      'successfully turned off',
    );

    $channel->clear_messages;

    # already off
    local $alice_droplet->{status} = 'off';
    send_message("synergy: box $method");
    like(
      single_message_text(),
      qr{That box is already (powered off|shut down)!},
      'if the box is already off, synergy says so'
    );
  };
}

subtest 'destroy' => sub {
  send_message('synergy: box destroy');
  like(
    single_message_text(),
    qr{powered on.*use /force to destroy it},
    'box is on, synergy suggests /force'
  );

  send_message('synergy: box destroy /force');
  like(single_message_text(), qr{^Box destroyed}, 'successfully force destroyed');

  local $alice_droplet->{status} = 'off';
  send_message('synergy: box destroy');
  like(single_message_text(), qr{^Box destroyed}, 'already off: successfully destroyed');
};

my %CREATE_RESPONSES = (
  first_droplet_fetch => gen_response(200, {
    droplets => []
  }),

  snapshot_fetch => gen_response(200, {
    snapshots => [{
      id => 42,
      name => 'fminabox-bullseye-20200202',
    }]
  }),

  ssh_key_fetch => gen_response(200, {
    ssh_keys => [{
      name => 'fminabox',
      id => 99,
    }],
  }),

  droplet_create => gen_response(201, {
    droplet => { id => 8675309 },
    links => {
      actions => [{ id => 215 }],
    },
  }),

  action_fetch => gen_response(200, {
    action => { status => 'completed' }
  }),

  last_droplet_fetch => gen_response(200, {
    droplets => [ $alice_droplet ],
  }),

  dns_fetch => gen_response(200, {}),
  dns_post  => gen_response(200, {}),
);

subtest 'create' => sub {
  undef $droplet_guard;

  my $box_name_re = qr{[-a-z0-9.]+}i;

  my $do_create = sub (%override) {
    my $wait = delete $override{wait} // 0;
    my $resp_for = sub ($key) { $override{$key} // $CREATE_RESPONSES{$key} };
    my $msg = $override{message} // "box create";

    @DO_RESPONSES = (
      $resp_for->('first_droplet_fetch'),
      $resp_for->('snapshot_fetch'),
      $resp_for->('ssh_key_fetch'),
      $resp_for->('droplet_create'),
      $resp_for->('action_fetch'),
      $resp_for->('last_droplet_fetch'),
      $resp_for->('dns_fetch'),
      $resp_for->('dns_post'),
    );

    send_message(
      "synergy: $msg",
      $channel->default_from,
      ($wait ? { seconds => $wait } : ()),
    );

    my @texts = map {; $_->{text} } $channel->sent_messages;
    $channel->clear_messages;
    return @texts;
  };

  subtest 'already have a box' => sub {
    my @texts = $do_create->(
      first_droplet_fetch => $CREATE_RESPONSES{last_droplet_fetch},
    );

    is(@texts, 1, 'sent a single failure message');
    like($texts[0], qr{This box already exists}, 'message seems ok');
  };

  subtest 'good create' => sub {
    my @texts = $do_create->(wait => 6);
    is(@texts, 2, 'sent two messages: please hold, then completion');
    cmp_deeply(
      \@texts,
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{Box created: name: \Qalice-bullseye.box.fm.local\E}),
      ],
      'normal create with defaults seems fine'
    );
  };

  subtest 'bad snapshot / ssh key' => sub {
    # This is racy, because Future->needs_all fails immediately with the first
    # failure, and depending on what order the reactor decides to fire off the
    # requests in, it might get one before the other. That's fine, I think,
    # because all we care about is that there's some useful message.
    my @texts = $do_create->(
      snapshot_fetch => gen_response(200 => { snapshots => [] }),
    );

    cmp_deeply(
      \@texts,
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{find a DO (snapshot|ssh key)}),
      ],
      'no snapshot, messages ok'
    );

    @texts = $do_create->(
      ssh_key_fetch => gen_response(200 => { ssh_keys => [] }),
    );

    cmp_deeply(
      \@texts,
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{find a DO (snapshot|ssh key)}),
      ],
      'no ssh key, messages ok'
    );
  };

  subtest 'failed create' => sub {
    my @texts = $do_create->(droplet_create => gen_response(200 => {}));
    is(@texts, 2, 'sent two messages');
    cmp_deeply(
      \@texts,
      [
        re(qr{Creating $box_name_re}),
        re(qr{There was an error creating the box}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'failed action fetch' => sub {
    my @texts = $do_create->(
      action_fetch => gen_response(200 => {
        action => { status => 'errored' },
      }),
      wait => 6,
    );
    cmp_deeply(
      \@texts,
      [
        re(qr{Creating $box_name_re}),
        re(qr{Something went wrong while creating box}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'good create with non-default version' => sub {
    my $foo_droplet = dclone($alice_droplet);
    $foo_droplet->{name} =~ s/bullseye/foo/;

    my @texts = $do_create->(
      message => 'box create /version foo',
      snapshot_fetch => gen_response(200, {
        snapshots => [{
          id => 42,
          name => 'fminabox-foo-20201004',
        }]
      }),
      last_droplet_fetch => gen_response(200, {
        droplets => [ $foo_droplet ],
      }),
      wait => 6,
    );

    cmp_deeply(
      \@texts,
      [
        re(qr{Creating $box_name_re in nyc3}),
        re(qr{Box created: name: \Qalice-foo.box.fm.local\E}),
      ],
      'got our two normal messages'
    );
  };
};

done_testing;
