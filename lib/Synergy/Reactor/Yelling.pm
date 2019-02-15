use v5.24.0;
use warnings;
package Synergy::Reactor::Yelling;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'yell_more',
    method    => 'handle_mumbling',
    exclusive => 0,
    predicate => sub ($self, $e) {
      return unless $e->from_channel->isa('Synergy::Channel::Slack');

      my $channel_id = $e->conversation_address;
      my $channel = $e->from_channel->slack->channels->{$channel_id}{name};

      return unless $channel eq 'yelling';

      my $text = $e->text;
      $text =~ s/[#@](?:\S+)//g; # don't complain about @rjbs
      return $text =~ /\p{Ll}/;
    },
  };
}

sub handle_mumbling ($self, $event) {
  $event->reply("YOU'RE MUMBLING.");
}

1;
