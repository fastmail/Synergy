use v5.32.0;
use warnings;
package Synergy::Reactor::Upgrade;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use File::pushd;
use File::Find;
use Future::AsyncAwait;
use Path::Tiny;
use Synergy::CommandPost;

has git_dir => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# Something like: 'origin master'
has fetch_spec => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has files_to_not_test => (
  traits  => [ 'Array' ],
  handles => { 'files_to_not_test' => 'elements' },
  default => sub {  []  },
);

async sub start ($self) {
  if (my $state = $self->fetch_state) {
    my $to_channel = $state->{restart_channel_name};
    my $to_address = $state->{restart_to_address};
    my $version_desc = $state->{restart_version_desc} // $self->get_version_desc;

    if ($to_channel && $to_address) {
      my $channel = $self->hub->channel_named($to_channel);

      $channel->readiness->on_done(sub {
        $channel->send_message($to_address, "Restarted! Now at version $version_desc")->retain;

        # Notified. Maybe. Don't notify again
        $self->save_state({});
      });
    }
  }

  return;
}

command upgrade => {
  help => "*upgrade*: upgrade Synergy to the latest version",
} => async sub ($self, $event, $rest) {
  if (length $rest && $rest !~ /\Ayour gr[ae]y matter\z/) {
    return await $event->error_reply("That's not how upgrading works.");
  }

  my $old_version = $self->get_version;

  my $spec = $self->fetch_spec;

  my $status;

  my sub block ($s) {
    $s =~ s{\n$}{};
    return "\n```\n$s\n```\n";
  }

  if (my $status_err = $self->git_do(
    "status --porcelain --untracked-files=no",
    \$status,
  )) {
    return await $event->reply("Failed to git status: " . block($status_err));

  }

  if ($status) {
    return await $event->reply("git directory dirty, can't upgrade: " . block($status));
  }

  if (my $fetch_err = $self->git_do("fetch $spec")) {
    return await $event->reply("git fetch $spec failed: " . block($fetch_err));
  }

  if (my $reset_err = $self->git_do("reset --hard FETCH_HEAD")) {
    return await $event->reply("git reset --hard FETCH_HEAD failed: " . block($reset_err));
  }

  my $new_version = $self->get_version;

  if ($new_version eq $old_version) {
    return await $event->reply("Looks like we're already at the latest! ($new_version)");
  }

  if (my $err = $self->check_next) {
    $event->reply("Upgrade failed. Version $new_version has problems: " . block($err));

    if (my $reset_err = $self->git_do("reset --hard $old_version")) {
      $event->reply("Failed to reset back to old version $old_version. Manual intervention probably required. Error: " . block($reset_err));
    }

    return;
  }

  $self->save_state({
    restart_channel_name => $event->from_channel->name,
    restart_to_address   => $event->conversation_address,
    restart_version_desc => $self->get_version_desc,
  });

  my $f = await $event->reply("Upgraded from $old_version to $new_version; Restarting...");

  # Why is this a SIGINT and not just an exit?
  kill 'INT', $$;

  return;
};

command version => {
  help => "show the version of my current brain",
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->error_reply("It's just `version`, no arguments!");
  }

  return await $event->reply("My version is: " . $self->get_version_desc);
};

sub git_do ($self, $cmd, $output = undef) {
  my $guard = pushd($self->git_dir);

  my $out = `git $cmd 2>&1`;

  if ($output) {
    $$output = $out;
  }

  return $? == 0 ? undef : $out;
}

sub get_version ($self) {
  my $output;

  $self->git_do(
    "log -n 1 --pretty=%h",
    \$output,
  );

  chomp($output);

  $output;
}

sub get_version_desc ($self) {
  my $output;

  $self->git_do(
    "log -n 1 --pretty=tformat:'[%h] %s' --abbrev-commit",
    \$output,
  );

  chomp($output);

  $output;
}

my sub add_use_line ($data_ref, $skip) {
  return if $skip->{$File::Find::name};

  return unless -f $_;
  return unless /\.pm$/;

  my $name = "$File::Find::name";

  $name =~ s/^lib\///;
  $name =~ s/\//::/g;
  $name =~ s/\.pm//;

  $$data_ref .= "use $name;\n";
}

sub check_next ($self) {
  my $data = "use lib qw(lib);\n";

  my %skip = map {; $_ => 1 } $self->files_to_not_test;

  find(sub { add_use_line(\$data, \%skip) }, 'lib/');

  my $f = Path::Tiny->tempfile;
  $f->spew($data);

  my $out = `$^X -cw $f 2>&1`;
  return $out // "failed" if $?;

  return;
}

1;
