use v5.24.0;
use warnings;
package Synergy::Reactor::Upgrade;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(lexical_subs signatures);
use namespace::clean;
use File::pushd;
use File::Find;
use Path::Tiny;

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

sub start ($self) {
  if (my $state = $self->fetch_state) {
    my $to_channel = $state->{restart_channel_name};
    my $to_address = $state->{restart_to_address};
    my $version_desc = $state->{restart_version_desc} // $self->get_version_desc;

    if ($to_channel && $to_address) {
      $self->hub->channel_named($to_channel)
           ->send_message($to_address, "Restarted! Now at version $version_desc");
    }

    # Notified. Maybe. Don't notify again
    $self->save_state({});
  }
}
sub listener_specs {
  return {
    name      => 'Upgrade',
    method    => 'handle_upgrade',
    predicate => sub ($self, $e) {
      my $text = lc $e->text;

      $e->was_targeted && (
           $text eq 'upgrade'
        || $text eq 'upgrade your grey matter'
        || $text eq 'upgrade your gray matter'
      );
    },
  },
  {
    name      => 'Version',
    method    => 'handle_version',
    predicate => sub ($self, $e) {
      my $text = lc $e->text;

      $e->was_targeted && $text eq 'version';
    },
  };
}

sub handle_upgrade ($self, $event) {
  $event->mark_handled;

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
    $event->reply("Failed to git status: " . block($status_err));

    return;
  } elsif ($status) {
    $event->reply("git directory dirty, can't upgrade: " . block($status));

    return;
  }

  if (my $fetch_err = $self->git_do("fetch $spec")) {
    $event->reply("git fetch $spec failed: " . block($fetch_err));

    return;
  }

  if (my $reset_err = $self->git_do("reset --hard FETCH_HEAD")) {
    $event->reply("git reset --hard FETCH_HEAD failed: " . block($reset_err));

    return;
  }

  my $new_version = $self->get_version;

  if ($new_version eq $old_version) {
    $event->reply("Looks like we're already at the latest! ($new_version)");

    return;
  }

  if (my $err = $self->check_next) {
    $event->reply("Ugrade failed. Version $new_version has problems: " . block($err));

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

  my $f = $event->reply("Upgraded from $old_version to $new_version; Restarting...");
  $f->on_done(sub {
    # Why is this a SIGINT and not just an exit?
    kill 'INT', $$;
  });
}

sub handle_version ($self, $event) {
  $event->reply("My version is: " . $self->get_version_desc);

  $event->mark_handled;

  return;
}

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

sub check_next {
  my $data = "use lib qw(lib);\n";

  find(sub { wanted(\$data) }, 'lib/');

  my $f = Path::Tiny->tempfile;
  $f->spew($data);

  my $out = `$^X -cw $f 2>&1`;
  return $out // "failed" if $?;

  return;
}

sub wanted {
  my $data = shift;

  return unless -f $_;
  return unless /\.pm$/;

  my $name = "$File::Find::name";

  $name =~ s/^lib\///;
  $name =~ s/\//::/g;
  $name =~ s/\.pm//;

  $$data .= "use $name;\n";
}

1;
