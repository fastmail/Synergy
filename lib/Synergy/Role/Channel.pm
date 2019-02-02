use v5.24.0;
use warnings;
package Synergy::Role::Channel;

use Moose::Role;
use experimental qw(signatures);
use namespace::clean;

with 'Synergy::Role::HubComponent';

requires qw(
  describe_event
  describe_conversation

  send_message
  send_message_to_user
);

sub start ($self) { }

# The idea here is that a channel might be able to keep track of errors and
# take some action in response to them. Synergy::Event::error_reply calls this
# with whatever the return value of the Channel's send_message is. (See
# Synergy::Channel::Slack for an example.)
sub note_error ($self, @send_message_response) { }

1;

=pod

=over 4

=item describe_conversation

A short (single-word) description for the conversation. For channels that don't
support multiple channels, just the name of the channel is probably fine.

=back
