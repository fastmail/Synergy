use v5.36.0;
package Synergy::Reactor::InABox;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use namespace::clean;

use Future::AsyncAwait;

use Dobby::BoxManager;
use Process::Status;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(bool_from_text reformat_help);
use String::Switches qw(parse_switches canonicalize_names);
use JSON::MaybeXS;
use Future::Utils qw(repeat);
use Text::Template;
use Time::Duration qw(ago);
use DateTime::Format::ISO8601;
use Path::Tiny;

has box_manager_config => (
  is => 'ro',
  required  => 1,
);

sub box_manager_for_event ($self, $event) {
  return Dobby::BoxManager->new({
    $self->box_manager_config->%*,

    dobby       => $self->dobby,

    error_cb    => sub ($error) { Synergy::X->throw_public($error) },
    log_cb      => sub ($log)   { $Logger->log($log) },
    message_cb  => sub ($msg)   { $event->reply($msg) },
    snippet_cb  => $self->_mk_snippet_cb($event),
  });
}

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

has ssh_key_id => (
  is  => 'ro',
  isa => 'Str',
  required => 1
);

has digitalocean_ssh_key_name => (
  is  => 'ro',
  isa => 'Str',
  default => 'synergy',
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

  # XXX Temporary
  obliterate => \&handle_obliterate,
);

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

command box => {
  help => reformat_help(<<~"EOH"),
    box is a tool for managing cloud-based fminabox instances

    All subcommands can take /version and /ident can be used to target a specific box. If not provided, defaults will be used.

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

  canonicalize_names($switches, {
    datacenter  => 'datacentre',
    region      => 'datacentre',
    tag         => 'ident',
  });

  my %switches = map { my ($k, @rest) = @$_; $k => \@rest } @$switches;

  for my $k (qw( version ident size datacentre )) {
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

sub _determine_version_and_ident ($self, $event, $switches) {
  # this convoluted mess is about figuring out:
  # - the version, by request or from prefs or implied
  # - the ident, by request or from the version
  # - if this is the "default" box, which sets the "$username.box" DNS name
  my $default_version = $self->get_user_preference($event->from_user, 'version')
                     // $self->default_box_version;

  my ($version, $ident) = delete $switches->@{qw(version ident)};
  $version = lc $version if $version;
  $ident = lc $ident if $ident;
  my $is_default_box = !($version || $ident);
  $version //= $default_version;
  $ident //= $version;

  # XXX check version and ident valid

  return ($version, $ident, $is_default_box);
}

sub _username_for ($self, $user) {
  my $pref = $self->get_user_preference($user, 'username');
  return $pref ? $pref : $user->username;
}

async sub handle_status ($self, $event, $switches) {
  my $boxman   = $self->box_manager_for_event($event);
  my $droplets = await $boxman->get_droplets_for(
    $self->_username_for($event->from_user)
  );

  if (@$droplets) {
    return await $event->reply(join "\n",
      "Your boxes: ",
      map { $self->_format_droplet($_) } @$droplets,
    );
  }

  return await $event->reply("You don't seem to have any boxes.");
}

async sub handle_image ($self, $event, $switches) {
  my ($version) = $self->_determine_version_and_ident($event, $switches);
  my $boxman   = $self->box_manager_for_event($event);

  my $snapshot = await $boxman->get_snapshot_for_version($version);

  return await $event->reply("Unable to find a snapshot for version $version") unless $snapshot;

  my $created_at = DateTime::Format::ISO8601->parse_datetime($snapshot->{created_at})->epoch;
  my $ago = ago(time - $created_at);
  return await $event->reply("Would create box from image '$snapshot->{name}' (created $ago)");
}

my %IS_CREATE_SWITCH = map {; $_ => 1 } qw( datacentre setup size nosetup );

async sub handle_create ($self, $event, $switches) {
  my ($version, $ident, $is_default_box) = $self->_determine_version_and_ident($event, $switches);

  my @unknown = sort grep {; !$IS_CREATE_SWITCH{$_} } keys %$switches;
  if (@unknown) {
    Synergy::X->throw_public(qq{I don't know these switches you gave to "box create": @unknown});
  }

  # XXX call /v2/sizes API to validate
  # https://developers.digitalocean.com/documentation/changelog/api-v2/new-size-slugs-for-droplet-plan-changes/
  my $size = $switches->{size} // $self->default_box_size;
  my $user = $event->from_user;
  my $username = $self->_username_for($user);

  if ($switches->{setup} && $switches->{nosetup}) {
    Synergy::X->throw_public("Passing /setup and /nosetup together is too weird for me to handle.");
  }

  my $should_run_setup  = $switches->{setup}    ? 1
                        : $switches->{nosetup}  ? 0
                        : $self->get_user_preference($user, 'setup-by-default');

  my $region = $switches->{datacentre} // $self->_region_for_user($user);

  my $spec = Dobby::BoxManager::ProvisionRequest->new({
    version   => $version,
    ident     => $ident,
    size      => $size,
    username  => $username,
    region    => $region,
    is_default_box   => $is_default_box,
    project_id       => $self->box_project_id,
    run_custom_setup => $should_run_setup,
    setup_switches   => $switches->{setup},
    extra_tags       => [ 'fminabox' ],

    ssh_key_id => $self->ssh_key_id,
    digitalocean_ssh_key_name => $self->digitalocean_ssh_key_name
  });

  my $boxman  = $self->box_manager_for_event($event);
  my $droplet = await $boxman->create_droplet($spec);
  return;
}

sub _mk_snippet_cb ($self, $event) {
  # If there's a pastebin/snippet capable reactor, use that.
  # Otherwise, discard stdout/stderr and just provide an error message.
  if ($self->snippet_reactor_name && $self->hub->reactor_named($self->snippet_reactor_name)) {
    my $reactor = $self->hub->reactor_named($self->snippet_reactor_name);
    return async sub ($snippet) {
      return await $reactor->post_gitlab_snippet($snippet);
    };
  }

  return async sub ($arg) {
    return;
  }
}

async sub handle_destroy ($self, $event, $switches) {
  my ($version, $ident) = $self->_determine_version_and_ident($event, $switches);

  my $force = delete $switches->{force};
  $force //= $self->get_user_preference($event->from_user, 'destroy-always-force');

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

  my $username = $self->_username_for($event->from_user);
  my $boxman   = $self->box_manager_for_event($event);

  await $boxman->find_and_destroy_droplet({
    username => $username,
    ident    => $ident,
    force    => $force,
  });

  return;
}

async sub handle_obliterate ($self, $event, $switches) {
  my $ident = $switches->{ident};

  unless ($ident) {
    Synergy::X->throw_public("You need to provide `/ident xyz-abc.box.fastmaildev.com`.");
  }

  unless ($ident =~ qr{\.box\.fastmaildev\.com\z}) {
    Synergy::X->throw_public("The /ident provided needs to end in `.box.fastmaildev.com`.");
  }

  my @droplets = await $self->dobby->get_all_droplets;
  my ($droplet) = grep {; $_->{name} eq $ident } @droplets;

  unless ($droplet) {
    Synergy::X->throw_public("I couldn't find that box.");
  }

  unless ($switches->{force}) {
    my $message = $self->_format_droplet($droplet);
    return await $event->reply("Would destroy this droplet, if you use /force:\n$message");
  }

  my $boxman = $self->box_manager_for_event($event);
  await $boxman->destroy_droplet($droplet, { force => 1 });

  return;
}

async sub handle_shutdown ($self, $event, $switches) {
  my (undef, $ident) = $self->_determine_version_and_ident($event, $switches);

  my $username = $self->_username_for($event->from_user);
  my $boxman   = $self->box_manager_for_event($event);
  await $boxman->take_droplet_action($username, $ident, 'shutdown');
}

async sub handle_poweroff ($self, $event, $switches) {
  my (undef, $ident) = $self->_determine_version_and_ident($event, $switches);

  my $username = $self->_username_for($event->from_user);
  my $boxman   = $self->box_manager_for_event($event);
  await $boxman->take_droplet_action($username, $ident, 'off');
}

async sub handle_poweron ($self, $event, $switches) {
  my (undef, $ident) = $self->_determine_version_and_ident($event, $switches);

  my $username = $self->_username_for($event->from_user);
  my $boxman   = $self->box_manager_for_event($event);
  await $boxman->take_droplet_action($username, $ident, 'on');
}

async sub handle_vpn ($self, $event, $switches) {
  my ($version, $ident, $is_default_box) = $self->_determine_version_and_ident($event, $switches);

  my $template = Text::Template->new(
    TYPE       => 'FILE',
    SOURCE     => $self->vpn_config_file,
    DELIMITERS => [ '{{', '}}' ],
  );

  my $boxman = $self->box_manager_for_event($event);
  my $config = $template->fill_in(HASH => {
    droplet_host => $boxman->box_name_for(
      $self->_username_for($event->from_user),
      ($is_default_box ? () : $ident)
    ),
  });

  await $event->from_channel->send_file_to_user($event->from_user, 'fminabox.conf', $config);

  await $event->reply("I sent you a VPN config in a direct message. Download it and import it into your OpenVPN client.");
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

__PACKAGE__->add_preference(
  name      => 'username',
  validator => async sub ($self, $value, @) {
    $value =~ /\A[a-z]+\z/ && return $value;
    return (undef, "That isn't a valid unix username.");
  },
  description => 'This is your unix username for managed boxes.',
);

1;
