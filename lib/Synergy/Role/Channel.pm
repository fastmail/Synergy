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

1;

=pod

=over 4

=item describe_conversation

A short (single-word) description for the conversation. For channels that don't
support multiple channels, just the name of the channel is probably fine.

=back
