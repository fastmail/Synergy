use v5.24.0;
use warnings;
package Synergy::Reactor::InABox;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;

use Synergy::Logger '$Logger';
use JSON::MaybeXS;
use Future::Utils qw(repeat);
use Safe::Isa '$_isa';
use Text::Template;
use Try::Tiny;

sub listener_specs {
  return {
    name      => 'box',
    method    => 'handle_box',
    exclusive => 1,
    predicate => sub ($self, $event) {
      $event->was_targeted && $event->text =~ /\Abox\b/i;
    },
    help_entries => [
      # I wanted to use <<~'END' but synhi gets confused. -- rjbs, 2019-06-03
      { title => 'box', text => <<'END'
box is a tool for managing cloud-based fminabox instances

subcommands:

• status: show some info about your box, including IP address, fminabox build it was built from, and its current power status
• create: create a new box. won't let you create more than one (for now)
• destroy: destroy your box. if its powered on, you have to shut it down first
• shutdown: gracefully shut down and power off your box
• poweroff: forcibly shut down and power off your box (like pulling the power)
• poweron: start up your box
• vpn: get an OpenVPN config file to connect to your box
END
      },
    ],
  };
}

has digitalocean_api_base => (
  is => 'ro',
  isa => 'Str',
  default => 'https://api.digitalocean.com/v2',
);

has digitalocean_api_token => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

sub _do_endpoint ($self, $endpoint) {
  return $self->digitalocean_api_base . $endpoint;
}
sub _do_headers ($self) {
  return (
    'Authorization' => 'Bearer ' . $self->digitalocean_api_token,
  );
}

has vpn_config_file => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has box_domain => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

my %command_handler = (
  info     => \&handle_status,
  status   => \&handle_status,
  create   => \&handle_create,
  destroy  => \&handle_destroy,
  shutdown => \&handle_shutdown,
  poweroff => \&handle_poweroff,
  poweron  => \&handle_poweron,
  vpn      => \&handle_vpn,
);

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

sub handle_box ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("Sorry, I don't know you.");
    return;
  }

  my ($box, $cmd, @args) = split /\s+/, $event->text;

  my $handler = $cmd ? $command_handler{$cmd} : undef;
  unless ($handler) {
    return $event->error_reply("usage: box [status|create|destroy|shutdown|poweroff|poweron|vpn]");
  }

  $handler->($self, $event, @args)
    ->else(sub ($reply, $category, @rest) {
      $event->error_reply($reply);
    })
    ->retain;
}

sub _do_request ($self, $method, $endpoint, $data = undef) {
  my %content;

  if ($data) {
    %content = (
      Content_Type => 'application/json',
      Content      => encode_json($data),
    );
  }

  return $self->hub->http_request(
    $method,
    $self->_do_endpoint($endpoint),
    $self->_do_headers,
    %content,
    async => 1,
  )->then(sub ($res) {
    unless ($res->is_success) {
      my $code = $res->code;
      $Logger->log([ "error talking to DO: %s", $res->as_string ]);
      return Future->fail(
        "Error talking to DO (got $code trying to $method $endpoint)",
        'http',
        { http_res => $res }
      );
    }

    return Future->done(1) if $method eq 'DELETE';

    my $data = decode_json($res->content);
    return Future->done($data);
  });
}

sub handle_status ($self, $event, @args) {
  $self->_get_droplet_for($event->from_user)
    ->then(sub ($droplet = undef) {
      if ($droplet) {
        return $event->reply("Your box: " . $self->_format_droplet($droplet));
      }

      return $event->reply("You don't seem to have a box.");
    });
}

sub handle_create ($self, $event, %args) {
  # do sanity checks before HTTP requests
  my $version = delete $args{'/version'}
             // $self->get_user_preference($event->from_user, 'version');

  if (keys %args) {
    return Future->fail(
      'error: syntax is "box create [ /version <version> ]"',
      'stop-processing',
    );
  }

  return $self->_get_droplet_for($event->from_user)
    ->then(sub ($maybe_droplet) {
      if ($maybe_droplet) {
        return Future->fail(
          "You already have a box: " . $self->_format_droplet($maybe_droplet),
          'stop-processing'
        );
      }

      return Future->done;
    })
    ->then(sub {
      # It would be nice to do this and the SSH key in parallel, but in
      # testing that causes *super* strange errors deep down in IO::Async if
      # one of the calls fails and the other does not, so here we'll just
      # admit defeat and do them in sequence. -- michael, 2020-04-02
      return $self->_get_snapshot($version);
    })
    ->then(sub ($snapshot) {
      return $self->_get_ssh_key->transform(done => sub ($ssh_key) {
        return ($snapshot, $ssh_key);
      });
    })
    ->then(sub ($snapshot, $ssh_key) {
      my $region = $self->_region_for_user($event->from_user);
      $event->reply("Creating $version box in $region, this will take a minute or two.");

      my %droplet_create_args = (
        name     => $self->_box_name_for_user($event->from_user),
        region   => $region,
        size     => 's-4vcpu-8gb',
        image    => $snapshot->{id},
        ssh_keys => [ $ssh_key->{id} ],
        tags     => [ 'fminabox' ],
      );

      $Logger->log([ "Creating droplet: %s", \%droplet_create_args ]);

      return $self->_do_request(POST => '/droplets', \%droplet_create_args);
    })
    ->then(sub ($data) {
      my $droplet = $data->{droplet};
      my $action_id = $data->{links}{actions}[0]{id};

      unless ($droplet) {
        return Future->fail(
          'There was an error creating the box. Try again.',
          'stop-processing'
        );
      }

      return $self->_do_action_status_f("/actions/$action_id");
    })
    ->then(sub ($status = undef) {
      # action status checks have been seen to time out or crash but the droplet
      # still turns up fine, so only consider it if we got a real response
      if ($status && $status ne 'completed') {
        return Future->fail(
          "Something went wrong while creating box, check the DigitalOcean console and maybe try again.",
          'stop-processing',
        );
      }

      return Future->done;
    })
    ->then(sub { $self->_get_droplet_for($event->from_user) })
    ->then(sub ($droplet) {
      if ($droplet) {
        $Logger->log([ "Created droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);
        $event->reply("Box created: " . $self->_format_droplet($droplet));
      } else {
        # We don't fail here, because we want to try to update DNS regardless.
        $event->error_reply(
          "Box was created, but now I can't find it! Check the DigitalOcean console and maybe try again."
        );
      }

      # we're assuming this succeeds. if not, well, the DNS is out of date. what
      # else can we do?
      return $self->_update_dns_for_user($event->from_user, $droplet->{networks}{v4}[0]{ip_address});
    });
}

sub handle_destroy ($self, $event, @args) {
  my $droplet;

  return $self->_get_droplet_for($event->from_user)
    ->then(sub ($maybe_droplet) {
      return Future->fail("You don't have a box.", 'stop-processing')
        unless $maybe_droplet;

      if ($maybe_droplet->{status} eq 'active' && ! grep { m{^/force$} } @args) {
        return Future->fail(
         "Your box is powered on. Shut it down first, or use /force to destroy it anyway.",
         'stop-processing'
       );
      }

      $droplet = $maybe_droplet;
      return Future->done($maybe_droplet)
    })
    ->then(sub ($droplet) {
      $Logger->log([ "Destroying droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);
      return $self->_do_request(DELETE => "/droplets/$droplet->{id}");
    })
    ->then(sub {
      $Logger->log([ "Destroyed droplet: %s", $droplet->{id} ]);
      $event->reply("Box destroyed.");
    });
}

sub _handle_power ($self, $event, $action) {
  my $remove_reactji = sub ($alt_text) {
    $event->private_reply($alt_text, {
      slack_reaction => {
        event => $event,
        reaction => '-vertical_traffic_light',
      },
    });
  };

  my $droplet;  # we could thread this through, but that's kind of tedious
  my $gerund = $action eq 'on'       ? 'powering on'
             : $action eq 'off'      ? 'powering off'
             : $action eq 'shutdown' ? 'shutting down'
             : die "unknown power action $action!";

  my $past_tense = $action eq 'shutdown' ? 'shut down' : "powered $action";

  $self->_get_droplet_for($event->from_user)
    ->then(sub ($maybe_droplet) {
      return Future->fail("You don't have a box.", 'stop-processing')
        unless $maybe_droplet;

      $droplet = $maybe_droplet;

      my $expect_off = $action eq 'on';

      if ( (  $expect_off && $droplet->{status} eq 'active')
        || (! $expect_off && $droplet->{status} ne 'active')
      ) {
        return Future->fail("Your box is already $past_tense!", 'stop-processing')
      }

      return Future->done($droplet);
    })
    ->then(sub ($droplet) {
      $Logger->log([ "$gerund droplet: %s", $droplet->{id} ]);
      $event->reply(
        "I'm pulling the levers, it'll be just a moment",
        {
          slack_reaction => {
            event => $event,
            reaction => 'vertical_traffic_light',
          }
        },
      );

      my $method = $action eq 'shutdown' ? 'shutdown' : "power_$action";

      return $self->_do_request(
        POST => "/droplets/$droplet->{id}/actions", { type => $method },
      );
    })
    ->then(sub ($data) { return Future->done($data->{action}) })
    ->then(sub ($do_action) {
      unless ($do_action) {
        $remove_reactji->('Error!');
        return Future->fail(
          "There was an error $gerund the box. Try again.",
          'stop-processing'
        );
      }

      return $self->_do_action_status_f("/droplets/$droplet->{id}/actions/$do_action->{id}");
    })
    ->then(sub ($status = undef) {
      # action status checks have been seen to time out or crash but the droplet
      # still turns up fine, so only consider it if we got a real response
      if ($status && $status ne 'completed') {
        $remove_reactji->('Error!');
        return Future->fail(
          "Something went wrong while $gerund box, check the DigitalOcean console and maybe try again.",
          'stop-processing',
        );
      }

      $remove_reactji->("$past_tense!");
      $event->reply("Your box has been $past_tense.");
    });
}

sub handle_shutdown ($self, $event, @args) {
  return $self->_handle_power($event, 'shutdown');
}

sub handle_poweroff ($self, $event, @args) {
  $self->_handle_power($event, 'off');
}

sub handle_poweron ($self, $event, @args) {
  return $self->_handle_power($event, 'on');
}

sub handle_vpn ($self, $event, @args) {
  my $template = Text::Template->new(
    TYPE       => 'FILE',
    SOURCE     => $self->vpn_config_file,
    DELIMITERS => [ '{{', '}}' ],
  );

  my $user = $event->from_user;

  my $config = $template->fill_in(HASH => {
    droplet_host => $self->_box_name_for_user($user),
  });

  $event->from_channel->send_file_to_user($event->from_user, 'fminabox.conf', $config);

  $event->reply("I sent you a VPN config in a direct message. Download it and import it into your OpenVPN client.");
}

sub _do_action_status_f ($self, $actionurl) {
  repeat {
    $self->_do_request(GET => $actionurl)
      ->then(sub ($data) {
        my $status = $data->{action}{status};
        return $status eq 'in-progress'
          ? $self->hub->loop->delay_future(after => 5)->then_done($status)
          : Future->done($status);
      })
  } until => sub ($f) { $f->get ne 'in-progress' };
}

sub _get_droplet_for ($self, $user) {
  return $self->_do_request(GET => '/droplets?per_page=200')
    ->then(sub ($data) {
      my ($droplet) = grep {; $_->{name} eq $self->_box_name_for_user($user) }
                      $data->{droplets}->@*;

      Future->done($droplet);
    });
}

sub _format_droplet ($self, $droplet) {
  return sprintf
    "name: %s  image: %s  ip: %s  region: %s  status: %s",
    $droplet->{name},
    $droplet->{image}{name},
    $droplet->{networks}{v4}[0]{ip_address},
    "$droplet->{region}{name} ($droplet->{region}{slug})",
    $droplet->{status};
}

sub _get_snapshot ($self, $version) {
  return $self->_do_request(GET => '/snapshots?per_page=200')
    ->then(sub ($data) {
      my ($snapshot) = sort { $b->{name} cmp $a->{name} }
                       grep { $_->{name} =~ m/^fminabox-\Q$version\E/ }
                       $data->{snapshots}->@*;

      if ($snapshot) {
        $Logger->log([ "Found snapshot: %s (%s)", $snapshot->{id}, $snapshot->{name} ]);
        return Future->done($snapshot);
      }

      $Logger->log([ "fminabox snapshot not found?!" ]);
      return Future->fail(
        "Hmm, I couldn't find a DO snapshot for fminabox-$version",
        'stop-processing'
      );
    });
}

sub _get_ssh_key ($self) {
  return $self->_do_request(GET => '/account/keys?per_page=200')
    ->then(sub ($data) {
      my ($ssh_key) = grep {; $_->{name} eq 'fminabox' } $data->{ssh_keys}->@*;

      if ($ssh_key) {
        $Logger->log([ "Found SSH key: %s (%s)", $ssh_key->{id}, $ssh_key->{name} ]);
        return Future->done($ssh_key);
      }

      $Logger->log([ "fminabox SSH key not found?!" ]);
      return Future->fail(
        "Hmm, I couldn't find a DO ssh key to use for fminabox",
        'stop-processing',
      );
    }
  );
}

sub _box_name_for_user ($self, $user) {
  return sprintf("%s.box.%s", $user->username, $self->box_domain);
}

sub _region_for_user ($self, $user) {
  my $dc = $self->get_user_preference($user, 'datacentre');
  return $dc if $dc;

  # this is incredibly stupid, but will do the right thing for the home
  # location of FM plumbing staff without a preference set
  my $tz = $user->time_zone;
  my ($area) = split '/', $tz;
  return
    $area eq 'Australia' ? 'sfo2' :
    $area eq 'Europe'    ? 'ams3' :
                           'nyc3';
}

sub _update_dns_for_user ($self, $user, $ip) {
  my $username = $user->username;

  my $base = '/domains/' . $self->box_domain . '/records';

  $self->_do_request(GET => "$base?per_page=200")
    ->then(sub ($data) {
      my ($record) = grep { $_->{name} eq "$username.box" } $data->{domain_records}->@*;
      Future->done($record);
    })
    ->then(sub ($record) {
      if ($record) {
        return $self->_do_request(PUT => "$base/$record->{id}", {
          data => $ip
        });
      }

      return $self->_do_request(POST => "$base", {
        type => 'A',
        name => "$username.box",
        data => $ip,
        ttl  => 30,
      });
    })
    ->then(sub { return Future->done })
    ->else(sub {
      # We don't actually care if this fails (what can we do?), so we
      # transform a failure into a success.
      $Logger->log("ignoring error when updating DNS with DO");
      return Future->done;
    });
}

__PACKAGE__->add_preference(
  name      => 'version',
  validator => sub ($self, $value, @) {
    my %known = map {; $_ => 1 } qw( jessie buster );

    $value = lc $value;

    unless ($known{$value}) {
      my $versions = join q{, }, sort keys %known;
      return (undef, "unknown version $value; known versions are: $versions");
    }

    return $value;
  },
  default   => 'jessie',
  description => 'Default Debian version for your fminabox',
);

__PACKAGE__->add_preference(
  name      => 'datacentre',
  validator => sub ($self, $value, @) {
    $value = lc $value;

    unless ($value =~ /\A[a-z0-9]+\z/) {
      return (undef, "Hmm, $value doesn't seem like a valid datacentre name.");
    }

    return $value;
  },
  default   => undef,
  description => 'The Digital Ocean data centre to spin up fminabox in',
);

1;
