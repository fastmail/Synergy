use v5.34.0;
package Synergy::Reactor::Register;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::Util qw(reformat_help);

responder register_me => {
  is_exclusive  => 1,
  is_targeted   => 1,
  matcher       => sub ($text, @) {
    $text =~ /\Aregister me as\s+(.+)\z/ ? [$1] : ()
  },
  help          => reformat_help(<<'EOH'),
Welcome aboard and nice to meet you! To introduce yourself, say

*register me as USERNAME*

USERNAME will become the name I'll know you by. This is the beginning of a
long and prosperous friendship, I can tell.
EOH
} => async sub ($self, $event, $username) {
  $event->mark_handled;

  my $directory = $self->hub->user_directory;

  if ($event->from_user) {
    my $name = $event->from_user->username;
    return await $event->error_reply("I already know who you are, $name!");
  }

  $username =~ s/\s*$//g;
  $username = lc $username;

  if ($username =~ /[^a-z]/) {
    return await $event->error_reply("Sorry, usernames must be all letters")
  }

  die "crazy case: event has no from address??" unless $event->from_address;

  if ($directory->user_named($username)) {
    my $err = join(q{ },
      "Well this is awkward. I already know someone named $username.",
      "If that's you, maybe you want <register identity> instead."
    );

    return await $event->error_reply($err);
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
    my $admin = $directory->master_user_string;
    return await $event->error_reply(
      "Something went wrong while trying to register you. Try talking to $admin."
    );
  }

  return await $event->reply("Hello, $username. Nice to meet you!");
};

1;
