use v5.36.0;
package Synergy::Reactor::InABox;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use namespace::clean;

use Future::AsyncAwait;

use Dobby::Client;
use Process::Status;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(bool_from_text reformat_help);
use String::Switches qw(parse_switches);
use Future::Utils qw(repeat);
use Text::Template;
use Time::Duration qw(ago);
use DateTime::Format::ISO8601;

# This SSH key, if given and present, will be used to connect to boxes after
# they're stood up to run commands. -- rjbs, 2023-10-20
has ssh_key_id => (
  is  => 'ro',
  isa => 'Str',
);

has digitalocean_ssh_key_name => (
  is  => 'ro',
  isa => 'Str',
  default => 'synergy',
);

has digitalocean_api_token => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has snippet_reactor_name => (
  is       => 'ro',
  isa      => 'Str',
);

has dobby => (
  is    => 'ro',
  lazy  => 1,
  default => sub ($self) {
    my $dobby = Dobby::Client->new(
      bearer_token => $self->digitalocean_api_token,
    );

    $self->loop->add($dobby);

    return $dobby;
  }
);

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

has box_project_id => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_project_id',
);

has box_datacentres => (
  is => 'ro',
  isa => 'ArrayRef',
  required => 1,
);

has default_box_version => (
  is => 'ro',
  isa => 'Str',
  default => 'bookworm',
);

has default_box_size => (
  is => 'ro',
  isa => 'Str',
  default => 'g-4vcpu-16gb',
);

has known_box_versions => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub ($self) {
    return [ $self->default_box_version ];
  },
);

my %command_handler = (
  info     => \&handle_status,
  status   => \&handle_status,
  create   => \&handle_create,
  destroy  => \&handle_destroy,
  shutdown => \&handle_shutdown,
  poweroff => \&handle_poweroff,
  poweron  => \&handle_poweron,
  image    => \&handle_image,
  vpn      => \&handle_vpn,
);

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

command box => {
  help => reformat_help(<<~"EOH"),
    box is a tool for managing cloud-based fminabox instances

    All subcommands can take /version and /tag can be used to target a specific box. If not provided, defaults will be used.

    • status: show some info about your boxes, including IP address, fminabox build it was built from, and its current power status
    • create: create a new box
    • destroy: destroy a box. if its powered on, you have to shut it down first
    • shutdown: gracefully shut down and power off your box
    • poweroff: forcibly shut down and power off your box (like pulling the power)
    • poweron: start up your box
    • image: Show what snapshot image the box would be created with
    • vpn: get an OpenVPN config file to connect to your box

    The following preferences exist:

    • version: which version to create by default
    • datacentre: which datacentre to create boxes in (if unset, chooses one near you)
    • setup-by-default: if true, run your setup on the box when it's ready
    EOH
#' # <-- idiotic thing to help Vim synhi cope with <<~, sorry -- rjbs, 2023-10-20
} => async sub ($self, $event, $rest) {
  unless ($event->from_user) {
    return await $event->error_reply("Sorry, I don't know you.");
  }

  my ($cmd, $args) = split /\s+/, $rest, 2;

  my $handler = $cmd ? $command_handler{$cmd} : undef;
  unless ($handler) {
    return await $event->error_reply("usage: box [status|create|destroy|shutdown|poweroff|poweron|image|vpn]");
  }

  my ($switches, $error) = parse_switches($args);
  return await $event->error_reply("couldn't parse switches: $error") if $error;

  my %switches = map { my ($k, @rest) = @$_; $k => \@rest } @$switches;

  # This should be simplified into a more generic "validate and normalize
  # switches" call. -- rjbs, 2023-10-20
  # Normalize datacentre
  if (exists $switches{datacentre} && exists $switches{datacenter}) {
    return await $event->error_reply("You can't use /datacentre and /datacenter at the same time!");
  }

  if (exists $switches{datacenter}) {
    $switches{datacentre} = delete $switches{datacenter};
  }

  for my $k (qw( version tag size datacentre )) {
    next unless $switches{$k};
    $switches{$k} = $switches{$k}[0];
  }

  eval {
    await $handler->($self, $event, \%switches);
  };

  if (my $error = $@) {
    if ($error->isa('Synergy::X') && $error->is_public) {
      await $event->error_reply($error->message);
    } else {
      $Logger->log([ "error from %s handler: %s", $cmd, $error ]);
      await $event->error_reply("Something weird happened and I've logged it. Sorry!");
    }
  }

  return;
};

sub _determine_version_and_tag ($self, $event, $switches) {
  # this convoluted mess is about figuring out:
  # - the version, by request or from prefs or implied
  # - the tag, by request or from the version
  # - if this is the "default" box, which sets the "$username.box" DNS name
  my $default_version = $self->get_user_preference($event->from_user, 'version')
                     // $self->default_box_version;

  my ($version, $tag) = delete $switches->@{qw(version tag)};
  $version = lc $version if $version;
  $tag = lc $tag if $tag;
  my $is_default_box = !($version || $tag);
  $version //= $default_version;
  $tag //= $version;

  # XXX check version and tag valid

  return ($version, $tag, $is_default_box);
}

async sub handle_status ($self, $event, $switches) {
  my $droplets = await $self->_get_droplets_for($event->from_user);

  if (@$droplets) {
    return await $event->reply(join "\n",
      "Your boxes: ",
      map { $self->_format_droplet($_) } @$droplets,
    );
  }

  return await $event->reply("You don't seem to have any boxes.");
}

# This is not here so we can set it to zero and get rate limited or see bugs in
# production.  It's here so we can make the tests run fast. -- rjbs, 2024-02-09
has post_creation_delay => (
  is => 'ro',
  default => 5,
);

async sub handle_image ($self, $event, $switches) {
  my ($version) = $self->_determine_version_and_tag($event, $switches);
  my $snapshot = await $self->_get_snapshot($version);
  return await $event->reply("Unable to find a snapshot for version $version") unless $snapshot;

  my $created_at = DateTime::Format::ISO8601->parse_datetime($snapshot->{created_at})->epoch;
  my $ago = ago(time - $created_at);
  return await $event->reply("Would create box from image '$snapshot->{name}' (created $ago)");
}

async sub handle_create ($self, $event, $switches) {
  my ($version, $tag, $is_default_box) = $self->_determine_version_and_tag($event, $switches);

  # XXX call /v2/sizes API to validate
  # https://developers.digitalocean.com/documentation/changelog/api-v2/new-size-slugs-for-droplet-plan-changes/
  my $size = $switches->{size} // $self->default_box_size;
  my $user = $event->from_user;

  if ($switches->{setup} && $switches->{nosetup}) {
    Synergy::X->throw_public("Passing /setup and /nosetup together is too weird for me to handle.");
  }

  my $should_run_setup  = $switches->{setup}    ? 1
                        : $switches->{nosetup}  ? 0
                        : $self->get_user_preference($user, 'setup-by-default');

  my $maybe_droplet = await $self->_get_droplet_for($user, $tag);

  if ($maybe_droplet) {
    Synergy::X->throw_public(
      "This box already exists: " . $self->_format_droplet($maybe_droplet)
    );
  }

  my $name = $self->_box_name_for($user, $tag);
  my $region = $switches->{datacentre} // $self->_region_for_user($user);
  $event->reply("Creating $name in $region, this will take a minute or two.");

  # It would be nice to do these in parallel, but in testing that causes
  # *super* strange errors deep down in IO::Async if one of the calls fails and
  # the other does not, so here we'll just admit defeat and do them in
  # sequence. -- michael, 2020-04-02
  my $snapshot = await $self->_get_snapshot($version);
  my %snapshot_regions = map {; $_ => 1 } $snapshot->{regions}->@*;

  unless ($snapshot_regions{$region}) {
    my $compatible_regions =
      join ', ',
      grep { $snapshot_regions{$_} } $self->box_datacentres->@*;

    if ($compatible_regions) {
      return await $event->reply(
        "I'm unable to create an fminabox in region '$region'.  Available compatible regions are $compatible_regions.  You can use /datacentre switch to specify a compatible one"
      );
    }

    return await $event->reply(
      "I'm unable to create an fminabox in region '$region'.  Unfortunately this snapshot is not available in any of my configured regions"
    );
  }

  my $ssh_key  = await $self->_get_ssh_key;

  my $username = $user->username;

  my %droplet_create_args = (
    name     => $name,
    region   => $region,
    size     => $size,
    image    => $snapshot->{id},
    ssh_keys => [ $ssh_key->{id} ],
    tags     => [ 'fminabox', "owner:$username" ],
  );

  $Logger->log([ "Creating droplet: %s", \%droplet_create_args ]);

  my $droplet = await $self->dobby->create_droplet(\%droplet_create_args);

  unless ($droplet) {
    Synergy::X->throw_public("There was an error creating the box. Try again.");
  }

  # We delay this because a completed droplet sometimes does not show up in GET
  # /droplets immediately, which causes annoying problems.  Waiting 5s is a
  # silly fix, but seems to work, and it's not like box creation is
  # lightning-fast anyway. -- michael, 2021-04-16
  await $self->hub->loop->delay_future(after => $self->post_creation_delay);

  $droplet = await $self->_get_droplet_for($user, $tag);

  if ($droplet) {
    $Logger->log([ "Created droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);
  } else {
    # We don't fail here, because we want to try to update DNS regardless.
    $event->error_reply(
      "Box was created, but now I can't find it! Check the DigitalOcean console and maybe try again."
    );
  }

  # Add it to the relevant project. If this fails, then...oh well.
  # -- ?
  if ($self->has_project_id) {
    await $self->dobby->add_droplet_to_project(
      $droplet->{id},
      $self->box_project_id
    );
  }

  # update the DNS name. we will assume this succeeds; if it fails the box
  # is still good and there's not really much else we can do.
  my $ip_address = $self->_ip_address_for_droplet($droplet);

  my @names = (
    $self->_dns_name_for($event->from_user, $tag),
    ($is_default_box ? $self->_dns_name_for($event->from_user) : ())
  );

  for my $name (@names) {
    $Logger->log("updating DNS names for $name");

    await $self->dobby->point_domain_record_at_ip(
      $self->box_domain,
      $name,
      $ip_address,
    );
  }

  if ($should_run_setup) {
    my $key_file = $self->ssh_key_id
                 ? ("$ENV{HOME}/.ssh/" . $self->ssh_key_id)
                 : undef;

    if ($key_file && -r $key_file) {
      await $event->reply(
        "Box created, will now run setup. Your box is: "
        . $self->_format_droplet($droplet)
      );

      return await $self->_setup_droplet(
        $event,
        $droplet,
        $key_file,
        $switches->{setup} // [], # might be undef if setting up by default
      );
    }

    return await $event->reply(
      "Box created.  I can't run setup because I have no SSH credentials. "
      . $self->_format_droplet($droplet)
    );
  }

  # We only get here if we shouldn't run setup.
  await $event->reply("Box created: " . $self->_format_droplet($droplet));
}

sub _validate_setup_args ($self, $args) {
  return !! (@$args == grep {; /\A[-.a-zA-Z0-9]+\z/ } @$args);
}

async sub _setup_droplet ($self, $event, $droplet, $key_file, $args = []) {
  my $ip_address = $self->_ip_address_for_droplet($droplet);

  unless ($self->_validate_setup_args($args)) {
    $event->reply("Your /setup arguments don't meet my strict and undocumented requirements, sorry.  I'll act like you provided none.");
    $args = [];
  }

  my $success;
  my $max_tries = 20;
  TRY: for my $try (1..$max_tries) {
    my $socket;
    eval {
      $socket = await $self->hub->loop->connect(addr => {
        family   => 'inet',
        socktype => 'stream',
        port     => 22,
        ip       => $ip_address,
      });
    };

    if ($socket) {
      # We didn't need the connection, just to know it worked!
      undef $socket;

      $Logger->log([
        "ssh on %s is up, will now move on to running setup",
        $ip_address,
      ]);

      $success = 1;

      last TRY;
    }

    my $error = $@;
    if ($error !~ /Connection refused/) {
      $Logger->log([
        "weird error connecting to %s:22: %s",
        $ip_address,
        $error,
      ]);
    }

    $Logger->log([
      "ssh on %s is not up, maybe wait and try again; %s tries remain",
      $ip_address,
      $max_tries - $try,
    ]);

    await $self->hub->loop->delay_future(after => 1);
  }

  unless ($success) {
    return await $event->reply("I couldn't connect to your box to set it up.");
  }

  # ssh to the box and touch a file for proof of life
  $Logger->log("about to run ssh!");

  my ($exitcode, $stdout, $stderr) = await $self->hub->loop->run_process(
    capture => [ qw( exitcode stdout stderr ) ],
    command => [
      "ssh",
        '-A',
        '-i', "$key_file",
        '-l', 'root',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'StrictHostKeyChecking=no',

      $ip_address,
      (
        qw( fmdev mysetup ),
        '--user', $event->from_user->username,
        '--',
        @$args
      ),
    ],
  );

  $Logger->log([ "we ran ssh: %s", Process::Status->new($exitcode)->as_struct ]);

  if ($exitcode == 0) {
    return await $event->reply("In-a-Box ($droplet->{name}) is now set up!");
  }

  my $message = "Something went wrong setting up your box.";

  # If there's a pastebin/snippet capable reactor, use that
  # If there isn't, and the current channel is slack, use a slack snippet
  # else, discard stdout/stderr and return only an error message
  if ($self->snippet_reactor_name && $self->hub->reactor_named($self->snippet_reactor_name)) {
    my %payload;
    $payload{title} = "In-a-Box setup failure ($droplet->{name})";
    $payload{file_name} = "In-a-Box-setup-failure-$droplet->{name}.txt";
    $payload{content} = "$stderr\n----(stdout)----\n$stdout";

    my $snippet_url = await $self->hub->reactor_named('gitlab')
      ->post_gitlab_snippet(\%payload);
    $message .= " Here's a link to the output: $snippet_url";
    return await $event->reply($message);
  }

  if ($event->from_channel->isa('Synergy::Channel::Slack')) {
    $message .= " Here's the output from setup:";

    my $content = "$stderr\n----(stdout)----\n$stdout";
    await $event->from_channel->slack->send_file($event->conversation_address, 'setup.log', $content);
  } else {
    $Logger->log("we ran ssh, but not via Slack, so stdout/stderr discarded");
  }

  return await $event->reply($message);
}

async sub handle_destroy ($self, $event, $switches) {
  my ($version, $tag) = $self->_determine_version_and_tag($event, $switches);

  my $force = delete $switches->{force};

  if (%$switches) {
    my $unrecognized = "";

    for my $k (keys %$switches) {
      $unrecognized .= "/$k $switches->{$k}->@* ";
    }

    $unrecognized =~ s/\s*$//;

    Synergy::X->throw_public(
      "Unrecognized switches ($unrecognized), refusing to take a destructive action"
    );
  }

  my $droplet = await $self->_get_droplet_for($event->from_user, $tag);

  unless ($droplet) {
    Synergy::X->throw_public(
      "That box doesn't exist: " . $self->_box_name_for($event->from_user, $tag)
    );
  }

  my $can_destroy
    = $self->get_user_preference($event->from_user, 'destroy-always-force') ? 1
    : $force                                                                ? 1
    : $droplet->{status} eq 'active'                                        ? 0
    :                                                                         1;

  unless ($can_destroy) {
    Synergy::X->throw_public(
      "That box is powered on. Shut it down first, or use /force to destroy it anyway."
    );
  }

  $Logger->log([ "Destroying dns entries of: %s", $droplet->{name} ]);

  await $self->dobby->remove_domain_records_for_ip(
    $self->box_domain,
    $self->_ip_address_for_droplet($droplet),
  );

  $Logger->log([ "Destroying droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);

  await $self->dobby->destroy_droplet($droplet->{id});

  $Logger->log([ "Destroyed droplet: %s", $droplet->{id} ]);
  return await $event->reply("Box destroyed: " . $self->_box_name_for($event->from_user, $tag));
}

async sub _handle_power ($self, $event, $action, $tag = undef) {
  my $remove_reactji = sub ($alt_text) {
    $event->private_reply($alt_text, {
      slack_reaction => {
        event => $event,
        reaction => '-vertical_traffic_light',
      },
    });
  };

  my $gerund = $action eq 'on'       ? 'powering on'
             : $action eq 'off'      ? 'powering off'
             : $action eq 'shutdown' ? 'shutting down'
             : die "unknown power action $action!";

  my $past_tense = $action eq 'shutdown' ? 'shut down' : "powered $action";

  my $droplet = await $self->_get_droplet_for($event->from_user, $tag);

  unless ($droplet) {
    Synergy::X->throw_public("I can't find a box to do that to!");
  }

  my $expect_off = $action eq 'on';

  if ( (  $expect_off && $droplet->{status} eq 'active')
    || (! $expect_off && $droplet->{status} ne 'active')
  ) {
    Synergy::X->throw_public("That box is already $past_tense!");
  }

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

  eval {
    await $self->dobby->take_droplet_action($droplet->{id}, $method);
  };

  if (my $error = $@) {
    $Logger->log([
      "error when taking %s action on droplet: %s",
      $method,
      $@,
    ]);

    $remove_reactji->('Error!');
    Synergy::X->throw_public(
      "Something went wrong while $gerund box, check the DigitalOcean console and maybe try again.",
    );
  }

  $remove_reactji->("$past_tense!");
  $event->reply("That box has been $past_tense.");

  return;
}

sub handle_shutdown ($self, $event, $switches) {
  my ($version, $tag) = $self->_determine_version_and_tag($event, $switches);

  return $self->_handle_power($event, 'shutdown', $tag);
}

sub handle_poweroff ($self, $event, $switches) {
  my ($version, $tag) = $self->_determine_version_and_tag($event, $switches);

  $self->_handle_power($event, 'off', $tag);
}

sub handle_poweron ($self, $event, $switches) {
  my ($version, $tag) = $self->_determine_version_and_tag($event, $switches);

  return $self->_handle_power($event, 'on', $tag);
}

async sub handle_vpn ($self, $event, $switches) {
  my ($version, $tag, $is_default_box) = $self->_determine_version_and_tag($event, $switches);

  my $template = Text::Template->new(
    TYPE       => 'FILE',
    SOURCE     => $self->vpn_config_file,
    DELIMITERS => [ '{{', '}}' ],
  );

  my $config = $template->fill_in(HASH => {
    droplet_host => $self->_box_name_for($event->from_user, ($is_default_box ? () : $tag)),
  });

  await $event->from_channel->send_file_to_user($event->from_user, 'fminabox.conf', $config);

  await $event->reply("I sent you a VPN config in a direct message. Download it and import it into your OpenVPN client.");
}

async sub _get_droplet_for ($self, $user, $tag = undef) {
  my $name = $self->_box_name_for($user, $tag);

  my $droplets = await $self->_get_droplets_for($user);

  my ($droplet) = grep {; $_->{name} eq $name } @$droplets;

  return $droplet;
}

async sub _get_droplets_for ($self, $user) {
  my $dobby = $self->dobby;
  my $username = $user->username;
  my $tag   = "owner:$username";

  my @droplets = await $dobby->get_droplets_with_tag($tag);

  return \@droplets;
}

sub _ip_address_for_droplet ($self, $droplet) {
  # we want the public address, not the internal VPC address that we don't use
  my ($ip_address) =
    map { $_->{ip_address} }
    grep { $_->{type} eq 'public'}
      $droplet->{networks}{v4}->@*;
  return $ip_address;
}

sub _format_droplet ($self, $droplet) {
  return sprintf
    "name: %s  image: %s  ip: %s  region: %s  status: %s",
    $droplet->{name},
    $droplet->{image}{name},
    $self->_ip_address_for_droplet($droplet),
    "$droplet->{region}{name} ($droplet->{region}{slug})",
    $droplet->{status};
}

async sub _get_snapshot ($self, $version) {
  my $dobby = $self->dobby;
  my $snaps = await $dobby->json_get_pages_of('/snapshots', 'snapshots');

  my ($snapshot) = sort { $b->{created_at} cmp $a->{created_at} }
                   grep { $_->{name} =~ m/^fminabox-\Q$version\E/ }
                   @$snaps;

  if ($snapshot) {
    return $snapshot;
  }

  Synergy::X->throw_public("no snapshot found for fminabox-$version");
}

async sub _get_ssh_key ($self) {
  my $dobby = $self->dobby;
  my $keys = await $dobby->json_get_pages_of("/account/keys", 'ssh_keys');

  my ($ssh_key) = grep {; $_->{name} eq $self->digitalocean_ssh_key_name } @$keys;

  if ($ssh_key) {
    $Logger->log([ "Found SSH key: %s (%s)", $ssh_key->@{ qw(id name) } ]);
    return $ssh_key;
  }

  $Logger->log([ "fminabox SSH key not found?!" ]);
  Synergy::X->throw_public("Hmm, I couldn't find a DO ssh key to use for fminabox!");
}

sub _dns_name_for ($self, $user, $tag = undef) {
  my $name = join '-', $user->username, ($tag ? $tag : ());
  return join '.', $name, 'box';
}

sub _box_name_for ($self, $user, $tag = undef) {
  return join '.', $self->_dns_name_for($user, $tag), $self->box_domain;
}

sub _region_for_user ($self, $user) {
  my $dc = $self->get_user_preference($user, 'datacentre');
  return $dc if $dc;

  # this is incredibly stupid, but will do the right thing for the home
  # location of FM plumbing staff without a preference set
  my $tz = $user->time_zone;
  my ($area) = split '/', $tz;
  return
    $area eq 'Australia' ? 'syd1' :
    $area eq 'Europe'    ? 'ams3' :
                           'nyc3';
}

__PACKAGE__->add_preference(
  name      => 'version',
  validator => async sub ($self, $value, @) {
    # Clearing is fine; we'll pick up the default elsewhere
    return undef unless defined $value;

    my %known = map {; $_ => 1 } $self->known_box_versions->@*;

    $value = lc $value;

    unless ($known{$value}) {
      my $versions = join q{, }, sort keys %known;
      return (undef, "unknown version $value; known versions are: $versions");
    }

    return $value;
  },
  default   => undef,
  description => 'Default Debian version for your fminabox',
);

__PACKAGE__->add_preference(
  name      => 'datacentre',
  validator => async sub ($self, $value, @) {
    # Clearing is fine; we'll pick up the default elsewhere
    return undef unless defined $value;

    my %known = map {; $_ => 1 } $self->box_datacentres->@*;

    $value = lc $value;

    unless ($known{$value}) {
      my $datacentres = join q{, }, sort keys %known;
      return (undef, "unknown datacentre $value; known datacentres are: $datacentres");
    }

    return $value;
  },
  default   => undef,
  description => 'The Digital Ocean data centre to spin up fminabox in',
);

__PACKAGE__->add_preference(
  name      => 'setup-by-default',
  validator => async sub ($self, $value, @) { return bool_from_text($value) },
  default   => 0,
  description => 'should box creation run setup by default?',
);

__PACKAGE__->add_preference(
  name      => 'destroy-always-force',
  validator => async sub ($self, $value, @) { return bool_from_text($value) },
  default   => 0,
  description => 'When destroying an active box, always act as if /force was passed',
);

1;
