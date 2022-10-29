use v5.34.0;
use warnings;
package Synergy::Reactor::Page;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use utf8;

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use List::Util qw(first);
use Synergy::CommandPost;

has page_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has pushover_channel_name => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_pushover_channel',
);

sub start ($self) {
  my $name = $self->page_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no page channel ($name) configured, cowardly giving up")
    unless $channel;
}

command page => {
  help => <<'END'
*page* tries to page somebody via their phone or pager.  This is generally
reserved for emergencies or at least "nobody is replying in chat!"

• *page `WHO`: `MESSAGE`*: send this message to that person's phone or pager
END
} => async sub ($self, $event, $rest) {
  my ($who, $what) = $event->text =~ m/^page\s+@?([a-z]+):?\s+(.*)/is;

  unless (length $who and length $what) {
    return await $event->error_reply("usage: page USER: MESSAGE");
  }

  my $user = $self->resolve_name($who, $event->from_user);

  unless ($user) {
    return await $event->error_reply("I don't know who '$who' is. Sorry! 😕");
  }

  my $paged = 0;

  if ($user->has_identity_for($self->page_channel_name) || $user->has_phone) {
    my $to_channel = $self->hub->channel_named($self->page_channel_name);

    my $from = $event->from_user ? $event->from_user->username
                                 : $event->from_address;

    $to_channel->send_message_to_user($user, "$from says: $what");

    $paged = 1;
  }

  if ($self->has_pushover_channel) {
    if ($user->has_identity_for($self->pushover_channel_name)) {
      my $to_channel = $self->hub->channel_named($self->pushover_channel_name);

      my $from = $event->from_user ? $event->from_user->username
                                   : $event->from_address;

      $to_channel->send_message_to_user($user, "$from says: $what");

      $paged = 1;
    }
  }

  if ($paged) {
    return await $event->reply("Page sent!");
  } else {
    return await $event->reply("I don't know how to page $who, sorry.");
  }
};

1;
