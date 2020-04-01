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
use Text::Template;

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
  info     => \&_handle_status,
  status   => \&_handle_status,
  create   => \&_handle_create,
  destroy  => \&_handle_destroy,
  shutdown => \&_handle_shutdown,
  poweroff => \&_handle_poweroff,
  poweron  => \&_handle_poweron,
  vpn      => \&_handle_vpn,
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

  $handler->($self, $event, @args);
}

sub _do_request ($self, $method, $endpoint, $content = undef) {
  return $self->hub->http_request(
    $method,
    $self->_do_endpoint($endpoint),
    $self->_do_headers,
    async => 1,
  )->then(sub ($res) {
    unless ($res->is_success) {
      $Logger->log([ "error talking to DO: %s", $res->as_string ]);
      return Future->fail('Error talking to DO', 'http', { http_res => $res });
    }

    my $data = decode_json($res->content);
    return Future->done($data);
  });
}

sub _handle_status ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  $event->reply("Your box: " . $self->_format_droplet($droplet));
}

sub _handle_create ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  if ($droplet) {
    $event->error_reply("You already have a box: " . $self->_format_droplet($droplet));
    return;
  }

  my $version;
  my $region = $self->_region_for_user($event->from_user);

  # This feels icky to me for some reason, but totally works.
  my %args = @args;
  if (@args == 0) {
    $version = $self->get_user_preference($event->from_user->username, 'version');
  } elsif (defined($args{'/version'})) {
    $version = $args{'/version'};
  } else {
    $event->error_reply("Error: Syntax is \"box create /version <version>\"");
    return;
  }

  $event->reply("Creating $version box in $region, this will take a minute or two.");

  my ($snapshot_id, $ssh_key_id) = Future->wait_all(
    $self->_get_snapshot($version),
    $self->_get_ssh_key,
  )->then(
    sub (@futures) {
      my @results = map  {; $_->{id} }
                    grep {; defined }
                    map  {; $_->get }
                    @futures;

      return Future->done(@results);
    }
  )->get;

  unless ($snapshot_id && $ssh_key_id) {
    $event->error_reply("Couldn't find snapshot of $version or SSH key, can't create box. Try again.");
    return;
  }

  my %droplet_create_args = (
    name     => $self->_box_name_for_user($event->from_user->username),
    region   => $region,
    size     => 's-4vcpu-8gb',
    image    => $snapshot_id,
    ssh_keys => [$ssh_key_id],
    tags     => ['fminabox'],
  );

  $Logger->log([ "Creating droplet: %s", encode_json(\%droplet_create_args) ]);

  ($droplet, my $action_id) = $self->hub->http_post(
    $self->_do_endpoint('/droplets'),
    $self->_do_headers,
    async        => 1,
    Content_Type => 'application/json',
    Content      => encode_json(\%droplet_create_args),
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error creating droplet: %s", $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      return Future->done($data->{droplet}, $data->{links}{actions}[0]{id});
    }
  )->get;

  unless ($droplet) {
    $event->error_reply("There was an error creating the box. Try again.");
    return;
  }

  my $status = $self->_do_action_status_f("/actions/$action_id")->get;

  # action status checks have been seen to time out or crash but the droplet
  # still turns up fine, so only consider it if we got a real response
  if ($status) {
    if ($status ne 'completed') {
      $event->error_reply("Something went wrong while creating the box, check the DigitalOcean console and maybe try again.");
      return;
    }
  }

  $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  if ($droplet) {
    $Logger->log([ "Created droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);
    $event->reply("Box created: ".$self->_format_droplet($droplet));
  }
  else {
    $event->error_reply("Box was created, but now I can't find it! Check the DigitalOcean console and maybe try again.");
  }

  # we're assuming this succeeds. if not, well, the DNS is out of date. what
  # else can we do?
  $self->_update_dns_for_user($event->from_user, $droplet->{networks}{v4}[0]{ip_address});
}

sub _handle_destroy ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  if ($droplet->{status} eq 'active' && !grep { m{^/force$} } @args) {
    $event->error_reply("Your box is powered on. Shut it down first, or use /force to destroy it anyway.");
    return;
  }

  $Logger->log([ "Destroying droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);

  my $destroyed = $self->hub->http_delete(
    $self->_do_endpoint("/droplets/$droplet->{id}"),
    $self->_do_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error deleting droplet %s", $res->as_string]);
        return Future->done;
      }
      return Future->done(1);
    }
  )->get;

  unless ($destroyed) {
    $event->error_reply("There was an error destroying the box. Try again.");
    return;
  }

  $Logger->log([ "Destroyed droplet: %s", $droplet->{id} ]);
  $event->reply("Box destroyed.");
}

sub _handle_shutdown ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  if ($droplet->{status} ne 'active') {
    $event->error_reply("Your box is already powered off!");
    return;
  }

  $Logger->log([ "Shutting down droplet: %s", $droplet->{id} ]);
  $event->reply(
    "I'm pulling the levers, it'll be just a moment",
    {
      slack_reaction => {
        event => $event,
        reaction => 'vertical_traffic_light',
      }
    },
  );

  my $remove_reactji = sub ($alt_text) {
    $event->private_reply($alt_text, {
      slack_reaction => {
        event => $event,
        reaction => '-vertical_traffic_light',
      },
    });
  };

  my $action = $self->_do_droplet_action_f($droplet->{id}, 'shutdown');
  unless ($action) {
    $remove_reactji->('Error!');
    $event->error_reply('There was an error shutting down the box. Try again.');
    return;
  }
  my $status = $self->_do_action_status_f("/droplets/$droplet->{id}/actions/$action->{id}")->get;

  # action status checks have been seen to time out or crash but the droplet
  # still turns up fine, so only consider it if we got a real response
  if ($status) {
    if ($status ne 'completed') {
      $remove_reactji->('Error!');
      $event->error_reply("Something went wrong while shutting down the box, check the DigitalOcean console and maybe try again.");
      return;
    }
  }

  $remove_reactji->('Shut down!');
  $event->reply("Your box has been shut down.");
}

sub _handle_poweroff ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  if ($droplet->{status} ne 'active') {
    $event->error_reply("Your box is already powered off!");
    return;
  }

  $Logger->log([ "Powering off droplet: %s", $droplet->{id} ]);
  $event->reply(
    "I'm pulling the levers, it'll be just a moment",
    {
      slack_reaction => {
        event => $event,
        reaction => 'vertical_traffic_light',
      }
    },
  );

  my $remove_reactji = sub ($alt_text) {
    $event->private_reply($alt_text, {
      slack_reaction => {
        event => $event,
        reaction => '-vertical_traffic_light',
      },
    });
  };

  my $action = $self->_do_droplet_action_f($droplet->{id}, 'power_off');
  unless ($action) {
    $remove_reactji->('Error!');
    $event->error_reply('There was an error powering off the box. Try again.');
    return;
  }
  my $status = $self->_do_action_status_f("/droplets/$droplet->{id}/actions/$action->{id}")->get;

  # action status checks have been seen to time out or crash but the droplet
  # still turns up fine, so only consider it if we got a real response
  if ($status) {
    if ($status ne 'completed') {
      $remove_reactji->('Error!');
      $event->error_reply("Something went wrong while powering off the box, check the DigitalOcean console and maybe try again.");
      return;
    }
  }

  $remove_reactji->('Powered off!');
  $event->reply("Your box has been powered off.");
}

sub _handle_poweron ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  if ($droplet->{status} eq 'active') {
    $event->error_reply("Your box is already powered on!");
    return;
  }

  $Logger->log([ "Powering on droplet: %s", $droplet->{id} ]);
  $event->reply(
    "I'm pulling the levers, it'll be just a moment",
    {
      slack_reaction => {
        event => $event,
        reaction => 'vertical_traffic_light',
      }
    },
  );

  my $remove_reactji = sub ($alt_text) {
    $event->private_reply($alt_text, {
      slack_reaction => {
        event => $event,
        reaction => '-vertical_traffic_light',
      },
    });
  };

  my $action = $self->_do_droplet_action_f($droplet->{id}, 'power_on');
  unless ($action) {
    $remove_reactji->('Error!');
    $event->error_reply('There was an error powering on the box. Try again.');
    return;
  }
  my $status = $self->_do_action_status_f("/droplets/$droplet->{id}/actions/$action->{id}")->get;

  # action status checks have been seen to time out or crash but the droplet
  # still turns up fine, so only consider it if we got a real response
  if ($status) {
    if ($status ne 'completed') {
      $remove_reactji->('Error!');
      $event->error_reply("Something went wrong while powering on box, check the DigitalOcean console and maybe try again.");
      return;
    }
  }

  $remove_reactji->('Powered on!');
  $event->reply("Your box has been powered on.");
}

sub _handle_vpn ($self, $event, @args) {
  my $template = Text::Template->new(
    TYPE       => 'FILE',
    SOURCE     => $self->vpn_config_file,
    DELIMITERS => [ '{{', '}}' ],
  );

  my $user = $event->from_user;

  my $config = $template->fill_in(HASH => {
    droplet_host => $user->username . '.box.' . $self->box_domain,
  });

  $event->from_channel->send_file_to_user($event->from_user, 'fminabox.conf', $config);

  $event->reply("I sent you a VPN config in a direct message. Download it and import it into your OpenVPN client.");
}

sub _do_droplet_action_f ($self, $droplet_id, $type) {
  $self->hub->http_post(
    $self->_do_endpoint("/droplets/$droplet_id/actions"),
    $self->_do_headers,
    async        => 1,
    Content_Type => 'application/json',
    Content      => encode_json({ type => $type }),
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error taking '%s' action on droplet %s: %s", $type, $droplet_id, $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      return Future->done($data->{action});
    }
  )->get;
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

sub _get_droplet_for ($self, $who) {
  return $self->_do_request(GET => '/droplets?per_page=200')
    ->then(sub ($data) {
      my ($droplet) = grep {; $_->{name} eq $self->_box_name_for_user($who) }
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
      } else {
        $Logger->log([ "fminabox snapshot not found?!" ]);
      }

      Future->done($snapshot);
    });
}

sub _get_ssh_key ($self) {
  return $self->_do_request(GET => '/account/keys?per_page=200')
    ->then(sub ($data) {
      my ($ssh_key) = grep {; $_->{name} eq 'fminabox' } $data->{ssh_keys}->@*;

      if ($ssh_key) {
        $Logger->log([ "Found SSH key: %s (%s)", $ssh_key->{id}, $ssh_key->{name} ]);
      } else {
        $Logger->log([ "fminabox SSH key not found?!" ]);
      }

      Future->done($ssh_key);
    }
  );
}

sub _box_name_for_user ($self, $user) {
  return $user.'.box.'.$self->box_domain;
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

  my $endpoint = '/domains/' . $self->box_domain . '/records?per_page=200';

  my $record = $self->_do_request(GET => $endpoint)
    ->then(sub ($data) {
      my ($record) = grep { $_->{name} eq "$username.box" } $data->{domain_records}->@*;
      Future->done($record);
    })->get;

  my $update_f;
  if ($record) {
    $update_f = $self->hub->http_put(
      $self->_do_endpoint('/domains/' . $self->box_domain . "/records/$record->{id}"),
      $self->_do_headers,
      async        => 1,
      Content_Type => 'application/json',
      Content      => encode_json({ data => $ip }),
    );
  }
  else {
    my $record = {
      type => 'A',
      name => "$username.box",
      data => $ip,
      ttl  => 30,
    };
    $update_f = $self->hub->http_post(
      $self->_do_endpoint('/domains/' . $self->box_domain . '/records'),
      $self->_do_headers,
      async        => 1,
      Content_Type => 'application/json',
      Content      => encode_json($record),
    );
  }

  $update_f->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error creating/update DNS record: %s", $res->as_string]);
      }
      return Future->done;
    }
  )->get;
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
