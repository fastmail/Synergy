use v5.24.0;
package Synergy::EventHandler::SlackID;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

sub start { }

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  return unless $rch->channel->can('slack');

  return unless $event->text =~ /slackid (\w+)/;

  return unless $event->was_targeted;

  my $who = $1;

  my $user = first { $_->{name} eq $who } values $rch->channel->slack->users->%*;

  unless ($user) {
    $rch->reply("Sorry, I don't know who $who is");

    return 1;
  }

  $rch->reply("Their slack ID is $user->{id}");

  return 1;
}

1;
