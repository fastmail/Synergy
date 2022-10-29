use v5.34.0;
use warnings;
package Synergy::Reactor::SlackID;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use List::Util qw(first);
use Synergy::CommandPost;

command slackid => {
} => async sub ($self, $event, $rest) {
  unless ($event->from_channel->can('slack')) {
    return await $self->error_reply("Sorry, you can't use *slackid* outside Slack");
  }

  unless ($rest =~ /\A[@#]?(\S+)\s*\z/i) {
    return await $self->error_reply("Sorry, that doesn't look like a Slack identifier.");
  }

  my $what = $1;

  if ($what =~ s/^#//) {
    my $channel = $event->from_channel->slack->channel_named($what);

    unless ($channel) {
      return await $event->error_reply("Sorry, I can't find #$what.");
    }

    return await $event->reply("The Slack id for #$what is $channel->{id}");
  }

  my $user = first { $_->{name} eq $what }
             values $event->from_channel->slack->users->%*;

  unless ($user) {
    return await $event->error_reply("Sorry, I don't know who $what is.");
  }

  return await $event->reply("The Slack id for $what is $user->{id}");
};

responder reload_slack => {
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($text, @) {
    if ($text =~ /^reload slack (users|channels)\z/i) {
      return [ $1 ];
    }

    return;
  },
} => async sub ($self, $event, $what) {
  $event->mark_handled;

  if ($what eq 'users') {
    $event->from_channel->slack->load_users;
    $event->from_channel->slack->load_dm_channels;
    return $event->reply('Slack users reloaded');
  }

  if ($what eq 'channels') {
    $event->from_channel->slack->load_channels;
    return $event->reply('Slack channels reloaded');
  }

  return $event->reply_error("Sorry, I didn't understand your reload command.");
};

1;
