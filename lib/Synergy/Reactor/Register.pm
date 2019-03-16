use v5.24.0;
package Synergy::Reactor::Register;
use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'initial registration',
    method    => 'handle_register_me',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return $e->was_targeted && $e->text =~ /^register me/i;
    },
  };
}

sub handle_register_me ($self, $event) {
  $event->mark_handled;
  my $directory = $self->hub->user_directory;

  if ($event->from_user) {
    my $name = $event->from_user->username;
    return $event->error_reply("I already know who you are, $name!");
  }

  # Do we want to allow numbers in usernames? I think no.
  my ($username) = $event->text =~ /^register me as\s+(.*)$/i;

  return $event->error_reply("usage: register me as [USERNAME]")
    unless $username;

  $username =~ s/\s*$//g;
  $username = lc $username;

  return $event->error_reply("Sorry, usernames must be all letters")
    if $username =~ /[^a-z]/;

  die "crazy case: event has no from address??" unless $event->from_address;

  if ($directory->user_named($username)) {
    my $err = join(q{ },
      "Well this is awkward. I already know someone named $username.",
      "If that's you, maybe you want <register identity> instead."
    );

    return $event->error_reply($err);
  }

  my $user = Synergy::User->new(
    directory => $directory,
    username  => $username,
    is_master => 0,
    identities => {
      $event->from_channel->name => $event->from_address,
    },
  );

  my $ok = $directory->register_user($user);

  unless ($ok) {
    my $master = $directory->master_user_string;
    return $event->error_reply(
      "Something went wrong while trying to register you. Try talking to $master."
    );
  }

  return $event->reply("Hello, $username. Nice to meet you!");
}

1;
