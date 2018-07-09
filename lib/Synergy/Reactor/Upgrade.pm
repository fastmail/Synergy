use v5.24.0;
package Synergy::Reactor::Upgrade;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use File::pushd;

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

  if (my $status_err = $self->git_do(
    "status --porcelain --untracked-files=no",
    \$status,
  )) {
    $event->reply("Failed to git status: $status_err");

    return;
  } elsif ($status) {
    $event->reply("git directory dirty, can't upgrade: $status");

    return;
  }

  if (my $fetch_err = $self->git_do("fetch $spec")) {
    $event->reply("git fetch $spec failed: $fetch_err");

    return;
  }

  if (my $reset_err = $self->git_do("reset --hard FETCH_HEAD")) {
    $event->reply("git reset --hard FETCH_HEAD failed: $reset_err");

    return;
  }

  my $new_version = $self->get_version;

  if ($new_version eq $old_version) {
    $event->reply("Looks like we're already at the latest! ($new_version)");

    return;
  }

  $event->reply("Upgraded from $old_version to $new_version; Restarting...");

  $self->save_state({
    restart_channel_name => $event->from_channel->name,
    restart_to_address   => $event->conversation_address,
    restart_version_desc => $self->get_version_desc,
  });

  my $timer = IO::Async::Timer::Countdown->new(
    delay => 1,
    on_expire => sub { kill 'INT', $$ }, # Why not just exit?
  );

  $self->hub->loop->add($timer);

  $timer->start;
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
    "log -n 1 --pretty=oneline --abbrev-commit",
    \$output,
  );

  chomp($output);

  $output;
}

1;
