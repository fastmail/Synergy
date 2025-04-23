package Synergy::BoxManager;
use Moose;

use v5.36.0;

use Carp ();
use Dobby::Client;
use Future::AsyncAwait;
use Path::Tiny;
use Process::Status;

has dobby => (
  is => 'ro',
  required => 1,
);

# This is not here so we can set it to zero and get rate limited or see bugs in
# production.  It's here so we can make the tests run fast. -- rjbs, 2024-02-09
has post_creation_delay => (
  is => 'ro',
  default => 5,
);

has box_domain => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

# error   - report to the user and stop processing
# message - report to the user and continue
# log     - write to syslog, continue; args may be String::Flogger-ed
# snippet - post a snippet and return its URL
for my $type (qw( error log message snippet )) {
  has "$type\_cb" => (
    is  => 'ro',
    isa => 'CodeRef',
    required => 1,
    traits   => [ 'Code' ],
    handles  => {
      "handle_$type" => 'execute',
    },
  );
}

after "handle_error" => sub ($self, $error_str, @) {
  # The error_cb should always die, meaning this should never be reached.  If
  # it is, it means somebody wrote an error_cb that doesn't die, so it is our
  # job to die on their behalf.  Like in that movie Infinity Pool.
  die "error_cb did not throw an error for: $error_str";
};

package Synergy::BoxManager::ProvisionRequest {
  use Moose;

  # This is here for sort of easy last minute validation.  It doesn't check
  # things like "what if the user said to run custom setup but not standard
  # setup".  At some point, you'll get weird results if you do weird things.

  has region      => (is => 'ro', isa => 'Str',     required => 1);
  has size        => (is => 'ro', isa => 'Str',     required => 1);
  has username    => (is => 'ro', isa => 'Str',     required => 1);
  has version     => (is => 'ro', isa => 'Str',     required => 1);

  has image_id    => (is => 'ro', isa => 'Str',     required => 0);

  has ident       => (is => 'ro', isa => 'Str',     required => 1);

  has extra_tags  => (is => 'ro', isa => 'ArrayRef[Str]', default => sub { [] });
  has project_id  => (is => 'ro', isa => 'Maybe[Str]');

  has is_default_box   => (is => 'ro', isa => 'Bool', default => 0);
  has run_custom_setup => (is => 'ro', isa => 'Bool', default => 0);
  has setup_switches   => (is => 'ro', isa => 'Maybe[ArrayRef]');

  has run_standard_setup => (is => 'ro', isa => 'Bool', default => 1);

  has ssh_key_id => (is  => 'ro', isa => 'Str', required => 1);
  has digitalocean_ssh_key_name => (is  => 'ro', isa => 'Str', default => 'synergy');

  no Moose;
  __PACKAGE__->meta->make_immutable;
}

async sub create_droplet ($self, $spec) {
  my $maybe_droplet = await $self->_get_droplet_for($spec->username, $spec->ident);

  if ($maybe_droplet) {
    $self->handle_error(
      "This box already exists: " . $self->_format_droplet($maybe_droplet)
    );
  }

  my $name = $self->box_name_for($spec->username, $spec->ident);

  my $region = $spec->region;
  $self->handle_message("Creating $name in $region, this will take a minute or two.");

  # It would be nice to do these in parallel, but in testing that causes
  # *super* strange errors deep down in IO::Async if one of the calls fails and
  # the other does not, so here we'll just admit defeat and do them in
  # sequence. -- michael, 2020-04-02
  my $snapshot_id = await $self->_get_snapshot_id($spec);
  my $ssh_key  = await $self->_get_ssh_key($spec);

  # We get this early so that we don't bother creating the Droplet if we're not
  # going to be able to authenticate to it.
  my $key_file = $self->_get_my_ssh_key_file($spec);

  my %droplet_create_args = (
    name     => $name,
    region   => $spec->region,
    size     => $spec->size,
    image    => $snapshot_id,
    ssh_keys => [ $ssh_key->{id} ],
    tags     => [ "owner:" . $spec->username, $spec->extra_tags->@* ],
  );

  $self->handle_log([ "Creating droplet: %s", \%droplet_create_args ]);

  my $droplet = await $self->dobby->create_droplet(\%droplet_create_args);

  unless ($droplet) {
    $self->handle_error("There was an error creating the box. Try again.");
  }

  # We delay this because a completed droplet sometimes does not show up in GET
  # /droplets immediately, which causes annoying problems.  Waiting 5s is a
  # silly fix, but seems to work, and it's not like box creation is
  # lightning-fast anyway. -- michael, 2021-04-16
  await $self->dobby->loop->delay_future(after => $self->post_creation_delay);

  $droplet = await $self->_get_droplet_for($spec->username, $spec->ident);

  if ($droplet) {
    $self->handle_log([ "Created droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);
  } else {
    # We don't fail here, because we want to try to update DNS regardless.
    $self->handle_message(
      "Box was created, but now I can't find it! Check the DigitalOcean console and maybe try again."
    );
  }

  # Add it to the relevant project. If this fails, then...oh well.
  # -- ?
  if ($spec->project_id) {
    await $self->dobby->add_droplet_to_project(
      $droplet->{id},
      $spec->project_id
    );
  }

  {
    # update the DNS name. we will assume this succeeds; if it fails the box is
    # still good and there's not really much else we can do.

    my $ip_address = $self->_ip_address_for_droplet($droplet);

    my $name = $self->_dns_name_for($spec->username, $spec->ident);
    $self->handle_log("setting up A records for $name");

    await $self->dobby->point_domain_record_at_ip(
      $self->box_domain,
      $name,
      $ip_address,
    );

    if ($spec->is_default_box) {
      my $cname = $self->_dns_name_for($spec->username);
      $self->handle_log("setting up CNAME records for $cname");

      # Very irritatingly, it seems you *must* provide the trailing dot when
      # *creating* the record, but *not* when destroying it.  I suppose there's
      # a way in which this is defensible, but it bugs me. -- rjbs, 2025-04-22
      await $self->dobby->point_domain_record_at_name(
        $self->box_domain,
        $cname,
        join(q{.}, $name, $self->box_domain, ''), # trailing dot
      );
    }
  }

  if ($spec->run_standard_setup or $spec->run_custom_setup) {
    $self->handle_message(
      "Box created, will now run setup. Your box is: "
      . $self->_format_droplet($droplet)
    );

    return await $self->_setup_droplet(
      $spec,
      $droplet,
      $key_file,
    );
  }

  # We didn't have to run any setup!
  $self->handle_message(
    "Box created. Your box is: " . $self->_format_droplet($droplet)
  );

  return;
}

async sub _get_snapshot_id ($self, $spec) {
  if (defined $spec->image_id) {
    return $spec->image_id;
  }

  my $region = $spec->region;

  my $snapshot = await $self->get_snapshot_for_version($spec->version);
  my %snapshot_regions = map {; $_ => 1 } $snapshot->{regions}->@*;

  unless ($snapshot_regions{$region}) {
    $self->handle_error("I'm unable to create an fminabox in the region '$region'.");
  }

  return $snapshot->{id};
}

sub _get_my_ssh_key_file ($self, $spec) {
  my $key_file = $spec->ssh_key_id
               ? path($spec->ssh_key_id)->absolute("$ENV{HOME}/.ssh/")
               : undef;

  unless ($key_file && -r $key_file) {
    $self->handle_log(["Cannot read SSH key for inabox setup (from %s)", $spec->ssh_key_id]);
    $self->handle_error(
      "No SSH credentials for running box setup. This is a problem - aborting."
    );
  }

  return $key_file;
}

async sub _setup_droplet ($self, $spec, $droplet, $key_file) {
  my $ip_address = $self->_ip_address_for_droplet($droplet);

  my $args = $spec->setup_switches // [];
  unless ($self->_validate_setup_args($args)) {
    $self->handle_message("Your /setup arguments don't meet my strict and undocumented requirements, sorry.  I'll act like you provided none.");
    $args = [];
  }

  my $success;
  my $max_tries = 20;
  TRY: for my $try (1..$max_tries) {
    my $socket;
    eval {
      $socket = await $self->dobby->loop->connect(addr => {
        family   => 'inet',
        socktype => 'stream',
        port     => 22,
        ip       => $ip_address,
      });
    };

    if ($socket) {
      # We didn't need the connection, just to know it worked!
      undef $socket;

      $self->handle_log([
        "ssh on %s is up, will now move on to running setup",
        $ip_address,
      ]);

      $success = 1;

      last TRY;
    }

    my $error = $@;
    if ($error !~ /Connection refused/) {
      $self->handle_log([
        "weird error connecting to %s:22: %s",
        $ip_address,
        $error,
      ]);
    }

    $self->handle_log([
      "ssh on %s is not up, maybe wait and try again; %s tries remain",
      $ip_address,
      $max_tries - $try,
    ]);

    await $self->dobby->loop->delay_future(after => 1);
  }

  unless ($success) {
    # Really, this is an error, but when called in Synergy, we wouldn't want
    # the user to be able to edit the "box create" message and try again.  The
    # Droplet was created, but now it's weirdly inaccessible.
    $self->handle_message("I couldn't connect to your box to set it up. A human will need to clean this up!");
    return;
  }

  my @setup_args = $spec->run_custom_setup ? () : ('--no-custom');

  my @ssh_command = (
    "ssh",
      '-A',
      '-i', "$key_file",
      '-l', 'root',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'StrictHostKeyChecking=no',

    $ip_address,
    (
      qw( fmdev mysetup ),
      '--user', $spec->username,
      @setup_args,
      '--',
      @$args
    ),
  );

  # ssh to the box and touch a file for proof of life
  $self->handle_log([ "about to run ssh: %s", \@ssh_command ]);

  my ($exitcode, $stdout, $stderr) = await $self->dobby->loop->run_process(
    capture => [ qw( exitcode stdout stderr ) ],
    command => [ @ssh_command ],
  );

  $self->handle_log([ "we ran ssh: %s", Process::Status->new($exitcode)->as_struct ]);

  if ($exitcode == 0) {
    $self->handle_message("In-a-Box ($droplet->{name}) is now set up!");
    return;
  }

  my %snippet = (
    title     => "In-a-Box setup failure ($droplet->{name})",
    file_name => "In-a-Box-setup-failure-$droplet->{name}.txt",
    content   => "$stderr\n----(stdout)----\n$stdout",
  );

  my $url = await $self->handle_snippet(\%snippet);

  if ($url) {
    $self->handle_message("Something went wrong setting up your box.  Here's more detail: $url");
  } else {
    $self->handle_message("Something went wrong setting up your box.");
  }

  return;
}

async sub find_and_destroy_droplet ($self, $arg) {
  my $username = $arg->{username};
  my $ident    = $arg->{ident};
  my $force    = $arg->{force};

  my $droplet = await $self->_get_droplet_for($username, $ident);

  unless ($droplet) {
    $self->handle_error(
      "That box doesn't exist: " . $self->box_name_for($username, $ident)
    );
  }

  await $self->destroy_droplet($droplet, { force => $arg->{force} });
}

async sub destroy_droplet ($self, $droplet, $arg) {
  my $can_destroy = $arg->{force} || $droplet->{status} ne 'active';

  unless ($can_destroy) {
    $self->handle_error(
      "That box is powered on. Shut it down first, or use force to destroy it anyway."
    );
  }

  my $ip_addr = $self->_ip_address_for_droplet($droplet);
  $self->handle_log([ "Destroying DNS records pointing to %s", $ip_addr ]);
  await $self->dobby->remove_domain_records_for_ip(
    $self->box_domain,
    $self->_ip_address_for_droplet($droplet),
  );

  # Is it safe to assume $droplet->{name} is the target name?  I think so,
  # given the create code. -- rjbs, 2025-04-22
  my $dns_name = $droplet->{name};
  $self->handle_log([ "Destroying CNAME records pointing to %s", $dns_name ]);
  await $self->dobby->remove_domain_records_cname_targeting($self->box_domain, $dns_name);

  $self->handle_log([ "Destroying droplet: %s (%s)", $droplet->{id}, $droplet->{name} ]);

  await $self->dobby->destroy_droplet($droplet->{id});

  $self->handle_log([ "Destroyed droplet: %s", $droplet->{id} ]);

  $self->handle_message("Box destroyed: " . $droplet->{name});
  return;
}

async sub take_droplet_action ($self, $username, $ident, $action) {
  my $gerund = $action eq 'on'       ? 'powering on'
             : $action eq 'off'      ? 'powering off'
             : $action eq 'shutdown' ? 'shutting down'
             : die "unknown power action $action!";

  my $past_tense = $action eq 'shutdown' ? 'shut down' : "powered $action";

  my $droplet = await $self->_get_droplet_for($username, $ident);

  unless ($droplet) {
    $self->handle_error("I can't find a box to do that to!");
  }

  my $expect_off = $action eq 'on';

  if ( (  $expect_off && $droplet->{status} eq 'active')
    || (! $expect_off && $droplet->{status} ne 'active')
  ) {
    $self->handle_error("That box is already $past_tense!");
  }

  $self->handle_log([ "$gerund droplet: %s", $droplet->{id} ]);

  $self->handle_message("I've started $gerund that box…");

  my $method = $action eq 'shutdown' ? 'shutdown' : "power_$action";

  eval {
    await $self->dobby->take_droplet_action($droplet->{id}, $method);
  };

  if (my $error = $@) {
    $self->handle_log([
      "error when taking %s action on droplet: %s",
      $method,
      $@,
    ]);

    $self->handle_error(
      "Something went wrong while $gerund box, check the DigitalOcean console and maybe try again.",
    );
  }

  $self->handle_message("That box has been $past_tense.");

  return;
}

async sub _get_ssh_key ($self, $spec) {
  my $dobby = $self->dobby;
  my $keys = await $dobby->json_get_pages_of("/account/keys", 'ssh_keys');

  my $want_key = $spec->digitalocean_ssh_key_name;
  my ($ssh_key) = grep {; $_->{name} eq $want_key } @$keys;

  if ($ssh_key) {
    $self->handle_log([ "Found SSH key: %s (%s)", $ssh_key->@{ qw(id name) } ]);
    return $ssh_key;
  }

  $self->handle_log("fminabox SSH key not found?!");
  $self->handle_error("Hmm, I couldn't find a DO ssh key to use for fminabox!");
}


sub _dns_name_for ($self, $username, $ident = undef) {
  my $name = join '-', $username, ($ident ? $ident : ());
  return join '.', $name, 'box';
}

sub box_name_for ($self, $username, $ident = undef) {
  return join '.', $self->_dns_name_for($username, $ident), $self->box_domain;
}

async sub _get_droplet_for ($self, $username, $ident) {
  my $name = $self->box_name_for($username, $ident);

  my $droplets = await $self->get_droplets_for($username);

  my ($droplet) = grep {; $_->{name} eq $name } @$droplets;

  return $droplet;
}

async sub get_droplets_for ($self, $username) {
  my $dobby = $self->dobby;
  my $tag   = "owner:$username";

  my @droplets = await $dobby->get_droplets_with_tag($tag);

  return \@droplets;
}

async sub get_snapshot_for_version ($self, $version) {
  my $dobby = $self->dobby;
  my $snaps = await $dobby->json_get_pages_of('/snapshots', 'snapshots');

  my ($snapshot) = sort { $b->{created_at} cmp $a->{created_at} }
                   grep { $_->{name} =~ m/^fminabox-\Q$version\E/ }
                   @$snaps;

  if ($snapshot) {
    return $snapshot;
  }

  $self->handle_error("no snapshot found for fminabox-$version");
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

sub _validate_setup_args ($self, $args) {
  return !! (@$args == grep {; /\A[-.a-zA-Z0-9]+\z/ } @$args);
}

1;
