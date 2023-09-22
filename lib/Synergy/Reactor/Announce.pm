use v5.32.0;
use warnings;
package Synergy::Reactor::Announce;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Carp;
use Future::AsyncAwait;
use Synergy::CommandPost;

has to_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has to_address => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

async sub start ($self) {
  my $name = $self->to_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no channel named $name, cowardly giving up")
    unless $channel;

  return;
}

command announce => {
  help => '*announce MESSAGE*: send a message to the general announcement place',
} => async sub ($self, $event, $rest) {
  $event->mark_handled;

  if ($event->from_channel->name eq $self->to_channel_name) {
    return await $event->error_reply("You're already using the target system!");
  }

  my $from = $event->from_user ? $event->from_user->username
                               : $event->from_address;

  $self->hub->channel_named($self->to_channel_name)
            ->send_message($self->to_address, "$from says: $rest");

  return await $event->reply("Sent!");
};

1;
