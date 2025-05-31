#!perl
use v5.36.0;

use lib 't/lib';

use Test::Requires {
  'Dobby::Client' => 0, # skip all if Dobby::Client isn't installed
};

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

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    inabox => {
      class                  => 'Synergy::Reactor::InABox',
      box_datacentres        => ['nyc3', 'sfo3'],
      default_box_version    => 'bullseye',
      digitalocean_api_token => '1234',
      vpn_config_file        => '',
      ssh_key_id => 'id_bogus',
      digitalocean_ssh_key_name => 'synergy',

      box_manager_config => {
        box_domain             => 'fm.local',
        post_creation_delay    => 0.01,
      },
    },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
    bob => undef,
  },
});

# Set up a bunch of nonsense
my $channel = $synergy->test_channel;

# Fake up responses from VO.
my @DO_RESPONSES;
my $DO_RESPONSE = gen_response(200, {});
$synergy->server->register_path(
  '/digital-ocean',
  sub {
    return shift @DO_RESPONSES if @DO_RESPONSES;
    return $DO_RESPONSE;
  },
  'test file',
);

my $url = sprintf("http://localhost:%s/digital-ocean", $synergy->server->server_port);

# Muck with the guts of Dobby to catch our fakes.
my $endpoint = Sub::Override->new(
  'Dobby::Client::api_base',
  sub { return $url },
);

# We assert that we have a key file in real use, but we nerf it in testing.
my $ssh_guard = Sub::Override->new(
  'Dobby::BoxManager::_get_my_ssh_key_file',
  sub { return '/dev/null' },
);

# We can't ssh to the box, so calling setup is pointless.
my $setup_guard = Sub::Override->new(
  'Dobby::BoxManager::_setup_droplet',
  sub { return Future->done },
);

# We can't ssh to the box, so checking mollyguard is pointless.
my $mg_guard = Sub::Override->new(
  'Dobby::BoxManager::mollyguard_status_for',
  sub { return Future->done({ ok => 1 }) },
);

# dumb convenience methods
sub gen_response ($code, $data) {
  my $json = encode_json($data);
  return Plack::Response->new($code, [], $json)->finalize;
}

sub cmp_replies ($text, $want, $desc = "got expected replies", $arg = {}) {
  my $result = $synergy->run_test_program([[
    send => {
      text => $text,
      from => $arg->{from} // $channel->default_from,
    },
  ]]);

  my @reply_texts = map {; $_->{text} } $channel->sent_messages;
  $channel->clear_messages;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  cmp_deeply(
    \@reply_texts,
    $want,
    $desc,
  )
}

# minimal data for _format_droplet
my $alice_droplet = {
  id     => 123,
  name   => 'bullseye.alice.fm.local',
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
  $DO_RESPONSE = gen_response(200, { droplets => [ $alice_droplet ] });

  cmp_replies(
    'synergy: box status',
    [ re(qr{Your boxes:\s+name: \Qbullseye.alice.fm.local\E}) ],
    'alice has a box and synergy says so'
  );

  $DO_RESPONSE = gen_response(200, { droplets => [ ] });

  cmp_replies(
    'synergy: box status',
    [ "You don't seem to have any boxes." ],
    'bob has no box and synergy says so'
  );
};

# the above has confirmed that we can talk to DO and get the box, so now we'll
# just fake that method up.
our $droplet_guard = Sub::Override->new(
  'Dobby::BoxManager::_get_droplet_for',
  sub { return Future->done($alice_droplet) },
);

subtest 'poweron' => sub {
  # already on
  cmp_replies(
    'synergy: box poweron',
    [ 'That box is already powered on!' ],
    'if the box is already on, synergy says so'
  );

  # now off
  local $alice_droplet->{status} = 'off';
  @DO_RESPONSES = (
    gen_response(200, { action => { id => 987 } }),
    gen_response(200, { action => { status => 'completed'   } }),
  );

  cmp_replies(
    'synergy: box poweron',
    [
      "I've started powering on that box…",
      "That box has been powered on.",
    ],
    "expected reply sequence from poweron",
  );
};

for my $method (qw(poweroff shutdown)) {
  subtest $method => sub {
    @DO_RESPONSES = (
      gen_response(200, { action => { id => 987 } }),
      gen_response(200, { action => { status => 'completed' } }),
    );

    cmp_replies(
      "synergy: box $method",
      [
        re(qr{I've started (powering off|shutting down) that box…}),
        re(qr{That box has been (powered off|shut down)}),
      ],
      'successfully turned off',
    );

    # already off
    local $alice_droplet->{status} = 'off';

    cmp_replies(
      "synergy: box $method",
      [ re(qr{That box is already (powered off|shut down)!}) ],
      'if the box is already off, synergy says so'
    );
  };
}

subtest 'destroy' => sub {
  cmp_replies(
    'synergy: box destroy',
    [ re(qr{powered on.*use force to destroy it}) ],
    'box is on, synergy suggests /force'
  );

  cmp_replies(
    'synergy: box destroy /tagg',
    [ re(qr{Unrecognized switches \(/tagg\)}) ],
    'An attempt to destroy with an unknown argument gives an error'
  );

  cmp_replies(
    'synergy: box destroy /force',
    [ re(qr{^Box destroyed}) ],
    'successfully force destroyed',
  );

  cmp_replies(
    'synergy: box destroy /force /tagg bar',
    [ re(qr{Unrecognized switches \(/tagg bar\)}) ],
    'An attempt to force destroy with an unknown argument gives an error'
  );

  local $alice_droplet->{status} = 'off';

  cmp_replies(
    'synergy: box destroy',
    [ re(qr{^Box destroyed}) ],
    'already off: successfully destroyed'
  );
};

my %CREATE_RESPONSES = (
  first_droplet_fetch => gen_response(200, {
    droplets => []
  }),

  snapshot_fetch => gen_response(200, {
    snapshots => [{
      id => 42,
      name => 'fminabox-bullseye-20200202',
      regions => [ 'nyc3', 'sfo3'],
    }]
  }),

  ssh_key_fetch => gen_response(200, {
    ssh_keys => [{
      name => 'synergy',
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

  my sub cmp_create_replies ($override, $want, $desc = "got expected replies") {
    my sub resp_for ($key) { $override->{$key} // $CREATE_RESPONSES{$key} }
    my $msg = $override->{message} // "box create";

    @DO_RESPONSES = (
      resp_for('first_droplet_fetch'),
      resp_for('snapshot_fetch'),
      resp_for('ssh_key_fetch'),
      resp_for('droplet_create'),
      resp_for('action_fetch'),
      resp_for('last_droplet_fetch'),
      resp_for('dns_fetch'),
      resp_for('dns_post'),
    );

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    cmp_replies(
      "synergy: $msg",
      $want,
      $desc,
    );
  }

  subtest 'already have a box' => sub {
    cmp_create_replies(
      {
        first_droplet_fetch => $CREATE_RESPONSES{last_droplet_fetch}
      },
      [ re(qr{This box already exists}) ],
    );
  };

  subtest 'good create' => sub {
    cmp_create_replies(
      {},
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{Box created, will now run setup\. Your box is: name: \Qbullseye.alice.fm.local\E}),
      ],
      'normal create with defaults seems fine',
    );
  };

  subtest 'bad snapshot region' => sub {
    cmp_create_replies(
      {
        snapshot_fetch => gen_response(200 => {
          snapshots => [{
            id => 42,
            name => 'fminabox-bullseye-20200202',
            regions => [ 'zzz', 'aaa'],
          }]
        }),
      },
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{I'm unable to create an fminabox in the region 'nyc3'\.}),
      ],
      'bad snapshot region, messages ok'
    );
  };

  subtest 'bad snapshot / ssh key' => sub {
    # This is racy, because Future->needs_all fails immediately with the first
    # failure, and depending on what order the reactor decides to fire off the
    # requests in, it might get one before the other. That's fine, I think,
    # because all we care about is that there's some useful message.
    cmp_create_replies(
      {
        snapshot_fetch => gen_response(200 => { snapshots => [] }),
      },
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{no snapshot found}),
      ],
      'no snapshot, messages ok'
    );

    cmp_create_replies(
      {
        ssh_key_fetch => gen_response(200 => { ssh_keys => [] }),
      },
      [
        re(qr{Creating $box_name_re in nyc3}i),
        re(qr{find a DO ssh key}),
      ],
      'no ssh key, messages ok'
    );
  };

  subtest 'failed create' => sub {
    cmp_create_replies(
      {
        droplet_create => gen_response(200 => {})
      },
      [
        re(qr{Creating $box_name_re}),
        re(qr{Something weird happened and I've logged it}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'failed action fetch' => sub {
    cmp_create_replies(
      {
        action_fetch => gen_response(200 => {
          action => { status => 'errored' },
        }),
      },
      [
        re(qr{Creating $box_name_re}),
        re(qr{Something weird happened and I've logged it}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'good create with non-default version' => sub {
    my $foo_droplet = dclone($alice_droplet);
    $foo_droplet->{name} =~ s/bullseye/foo/;

    cmp_create_replies(
      {
        message => 'box create /version foo',
        snapshot_fetch => gen_response(200, {
          snapshots => [{
            id => 42,
            name => 'fminabox-foo-20201004',
            regions => [ 'nyc3', 'sf03' ],
          }]
        }),
        last_droplet_fetch => gen_response(200, {
          droplets => [ $foo_droplet ],
        }),
      },
      [
        re(qr{Creating $box_name_re in nyc3}),
        re(qr{Box created, will now run setup\. Your box is: name: \Qfoo.alice.fm.local\E}),
      ],
      'got our two normal messages'
    );
  };
};

done_testing;
