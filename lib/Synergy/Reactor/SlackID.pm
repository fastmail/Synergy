use v5.24.0;
use warnings;
package Synergy::Reactor::SlackID;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

sub listener_specs {
  return (
    {
      name      => 'slackid',
      method    => 'handle_event',
      predicate => sub ($self, $event) {
        return unless $event->type eq 'message';

        return unless $event->from_channel->can('slack');

        return unless $event->was_targeted;

        return unless $event->text =~ /\A\s*slackid [@#]?(\w+)\s*\z/i;

        return 1;
      },
    },
    {
      name      => 'reload-slack-users',
      method    => 'handle_reload_slack',
      predicate => sub ($self, $event) {
        return unless $event->type eq 'message';
        return unless $event->was_targeted;
        return unless $event->from_channel->can('slack');

        return unless $event->text =~ /\Areload slack (users|channels)\z/in;
        return 1;
      },
    },
  );
}

sub handle_event ($self, $event) {
  $event->mark_handled;

  if ($event->text =~ /slackid \@?(\w+)/) {
    my $who = $1;
    my $user = first { $_->{name} eq $who }
               values $event->from_channel->slack->users->%*;

    return $event->error_reply("Sorry, I don't know who $who is")
      unless $user;

    return $event->reply("The Slack id for $who is $user->{id}");
  }

  if ($event->text =~ /slackid #(\w+)/) {
    my $ch_name = $1;
    my $channel = $event->from_channel->slack->channel_named($ch_name);

    return $event->error_reply("Sorry, I can't find #$ch_name.")
      unless $channel;

    return $event->reply("The Slack id for #$ch_name is $channel->{id}");
  }

  return $event->error_reply(qq{Sorry, I don't know how to resolve that.});
}

sub handle_reload_slack ($self, $event) {
  my ($what) = $event->text =~ /^reload slack (users|channels)/i;

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
}

1;
