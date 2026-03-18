#!perl
use v5.36.0;
use utf8;

use lib 't/lib';

use Test::Requires {
  'Dobby::TestClient' => 0, # skip all if Dobby::TestClient isn't installed
};

use Future;
use HTTP::Response;
use JSON::MaybeXS qw(encode_json);
use Storable qw(dclone);
use Sub::Override;
use Test::More;
use Test::Deep;

use Dobby::TestClient;
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
    alice => undef,
    bob   => undef,
  },
});

my $channel = $synergy->test_channel;

# Create a Dobby::TestClient and inject it into the InABox reactor so all
# Dobby API calls are intercepted without real network access.
my $dobby = Dobby::TestClient->new(bearer_token => '1234');
$synergy->loop->add($dobby);
my $dobby_guard = Sub::Override->new(
  'Synergy::Reactor::InABox::dobby',
  sub { $dobby },
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

# Return an HTTP::Response with JSON body, for use in register_url_handler.
sub json_res ($data, $code = 200) {
  my $res = HTTP::Response->new($code, 'OK');
  $res->header('Content-Type' => 'application/json');
  $res->content(encode_json($data));
  return $res;
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

# A size available in our configured datacentres, matching default_box_size.
my $test_size = {
  slug         => 'g-4vcpu-16gb',
  available    => 1,
  regions      => ['nyc3', 'sfo3'],
  price_hourly => 0.119,
  vcpus        => 4,
  memory       => 16384,
  disk         => 100,
  description  => 'General Purpose',
};

subtest 'status' => sub {
  $dobby->register_url_json('/droplets', { droplets => [ $alice_droplet ] });

  cmp_replies(
    'synergy: box status',
    [ re(qr{Your boxes:\s+name: \Qbullseye.alice.fm.local\E}) ],
    'alice has a box and synergy says so'
  );

  $dobby->register_url_json('/droplets', { droplets => [ ] });

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

  $dobby->register_url_json('/droplets/123/actions',     { action => { id => 987 } });
  $dobby->register_url_json('/droplets/123/actions/987', { action => { status => 'completed' } });

  cmp_replies(
    'synergy: box poweron',
    [
      "I've started powering on that box\x{2026}",
      "That box has been powered on.",
    ],
    "expected reply sequence from poweron",
  );
};

for my $method (qw(poweroff shutdown)) {
  subtest $method => sub {
    $dobby->register_url_json('/droplets/123/actions',     { action => { id => 987 } });
    $dobby->register_url_json('/droplets/123/actions/987', { action => { status => 'completed' } });

    cmp_replies(
      "synergy: box $method",
      [
        re(qr{I've started (powering off|shutting down) that box\x{2026}}),
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
  $dobby->register_url_json('/domains/fm.local/records', { domain_records => [] });
  $dobby->register_url_json('/droplets/123', {});

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

subtest 'create' => sub {
  undef $droplet_guard;

  my $box_name_re = qr{[-a-z0-9.]+}i;

  my sub setup_create ($override) {
    # /droplets is called as GET (check existence), POST (create), GET (fetch after create).
    my @droplet_get_responses = (
      $override->{first_droplet_fetch} // { droplets => [] },
      $override->{last_droplet_fetch}  // { droplets => [ $alice_droplet ] },
    );
    my $droplet_post_response = $override->{droplet_create} // {
      droplet => { id => 8675309 },
      links   => { actions => [{ id => 215 }] },
    };
    $dobby->register_url_handler('/droplets', sub ($req) {
      return json_res($req->method eq 'POST'
        ? $droplet_post_response
        : (shift @droplet_get_responses // { droplets => [] }));
    });

    $dobby->register_url_json('/snapshots',
      $override->{snapshot_data} // {
        snapshots => [{
          id      => 42,
          name    => 'fminabox-bullseye-20200202',
          regions => ['nyc3', 'sfo3'],
        }]
      }
    );

    $dobby->register_url_json('/sizes', { sizes => [ $test_size ] });

    $dobby->register_url_json('/account/keys',
      $override->{ssh_key_data} // {
        ssh_keys => [{ name => 'synergy', id => 99 }],
      }
    );

    $dobby->register_url_json('/actions/215',
      $override->{action_data} // { action => { status => 'completed' } }
    );

    # DNS: GET returns empty records; POST (create) returns empty object.
    $dobby->register_url_handler('/domains/fm.local/records', sub ($req) {
      return json_res($req->method eq 'POST' ? {} : { domain_records => [] });
    });
  }

  my sub cmp_create_replies ($override, $want, $desc = "got expected replies") {
    setup_create($override);
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    cmp_replies("synergy: " . ($override->{message} // "box create"), $want, $desc);
  }

  subtest 'already have a box' => sub {
    cmp_create_replies(
      { first_droplet_fetch => { droplets => [ $alice_droplet ] } },
      [ re(qr{This box already exists}) ],
    );
  };

  subtest 'good create' => sub {
    cmp_create_replies(
      {},
      [
        re(qr{Creating $box_name_re in NYC3}i),
        re(qr{Box created, will now unlock\.  Your box is: name: \Qbullseye.alice.fm.local\E}),
      ],
      'normal create with defaults seems fine',
    );
  };

  subtest 'bad snapshot region' => sub {
    # The snapshot is only in regions that don't overlap with any available
    # size/region combination, so find_provisioning_candidates comes up empty.
    cmp_create_replies(
      {
        snapshot_data => {
          snapshots => [{
            id      => 42,
            name    => 'fminabox-bullseye-20200202',
            regions => ['zzz', 'aaa'],
          }]
        },
      },
      [ re(qr{No available combination}) ],
      'bad snapshot region, messages ok'
    );
  };

  subtest 'bad snapshot / ssh key' => sub {
    cmp_create_replies(
      { snapshot_data => { snapshots => [] } },
      [ re(qr{no snapshot found}) ],
      'no snapshot, messages ok'
    );

    cmp_create_replies(
      { ssh_key_data => { ssh_keys => [] } },
      [
        re(qr{Creating $box_name_re in NYC3}i),
        re(qr{find a DO ssh key}),
      ],
      'no ssh key, messages ok'
    );
  };

  subtest 'failed create' => sub {
    cmp_create_replies(
      { droplet_create => {} },
      [
        re(qr{Creating $box_name_re}),
        re(qr{Something weird happened and I've logged it}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'failed action fetch' => sub {
    cmp_create_replies(
      { action_data => { action => { status => 'errored' } } },
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
        message       => 'box create /version foo',
        snapshot_data => {
          snapshots => [{
            id      => 42,
            name    => 'fminabox-foo-20201004',
            regions => ['nyc3', 'sfo3'],
          }]
        },
        last_droplet_fetch => { droplets => [ $foo_droplet ] },
      },
      [
        re(qr{Creating $box_name_re in NYC3}),
        re(qr{Box created, will now unlock\.  Your box is: name: \Qfoo.alice.fm.local\E}),
      ],
      'got our two normal messages'
    );
  };

  subtest 'good create with /setup' => sub {
    cmp_create_replies(
      { message => 'box create /setup' },
      [
        re(qr{Creating $box_name_re in NYC3}),
        re(qr{Box created, will now run setup\. Your box is: name: \Qbullseye.alice.fm.local\E}),
      ],
      'good create with /setup'
    );
  };
};

done_testing;
