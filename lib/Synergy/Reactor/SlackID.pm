use v5.36.0;
package Synergy::Reactor::SlackID;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;

use List::Util qw(first);
use Slack::BlockKit::Sugar -all => { -prefix => 'bk_' };
use Synergy::CommandPost;

command slackid => {
  help => '*slackid @person* or *slackid #channel*: provide the Slack ID for a thing'
} => async sub ($self, $event, $rest) {
  unless ($event->from_channel->can('slack')) {
    return await $event->error_reply("Sorry, you can't use *slackid* outside Slack");
  }

  unless ($rest =~ /\A[@#]?(\S+)\s*\z/i) {
    return await $event->error_reply("Sorry, that doesn't look like a Slack identifier.");
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
  help => "*reload slack `{users, channels}`*: reload Slack data; you shouldn't need this!",
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($self, $text, @) {
    if ($text =~ /^reload slack (users|channels)\z/i) {
      return [ $1 ];
    }

    return;
  },
} => async sub ($self, $event, $what) {
  $event->mark_handled;

  my $channel = $event->from_channel;

  unless ($channel->can('slack')) {
    return await $event->error_reply("Sorry, you can't use *slackid* outside Slack");
  }

  if ($what eq 'users') {
    $channel->slack->load_users;
    $channel->slack->load_dm_channels;
    return $event->reply('Slack users reloaded');
  }

  if ($what eq 'channels') {
    $channel->slack->load_channels;
    return $event->reply('Slack channels reloaded');
  }

  return $event->reply_error("Sorry, I didn't understand your reload command.");
};

command slacksnippet => {
} => async sub ($self, $event, $text) {
  my $channel = $event->from_channel;

  unless ($channel->can('slack')) {
    return await $event->error_reply("Sorry, you can't use *slackid* outside Slack");
  }

  my $text = join q{}, ("$text\n") x 25;

  await $channel->slack->send_file($event->conversation_address, 'snippet', $text);
  $event->reply("Here's what you said, as a snippet.");

  return;
};

command slackmarkdown => {
} => async sub ($self, $event, $text) {
  my $channel = $event->from_channel;

  unless ($channel->can('slack')) {
    return await $event->error_reply("Sorry, you can't use *slackid* outside Slack");
  }

  return await $event->reply(
    "...",
    {
      slack => bk_blocks(bk_markdown("## Good news\n\nI look *fabulous*.\n")),
    }
  );
};

1;
