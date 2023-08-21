use v5.34.0;
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
# take some action in response to them. Synergy::Event::reply calls this
# with itself and the future that ->send_message returns. (See
# Synergy::Channel::Slack for an example.)
sub note_reply ($self, $event, $future, $args = {}) { }

has _pre_message_hooks => (
  is => 'ro',
  isa => 'ArrayRef[CodeRef]',
  traits => ['Array'],
  lazy => 1,
  default => sub { [] },
  handles => {
    pre_message_hooks => 'elements',
    register_pre_message_hook => 'push',
  },
);

sub run_pre_message_hooks ($self, $event, $text_ref, $alts) {
  for my $hook ($self->pre_message_hooks) {
    $hook->($event, $text_ref, $alts);
  }
}

sub text_without_target_prefix ($self, $text, $me) {
  my $matched = $text =~ s/\A \s* \@? (\Q$me\E) (?=\W) [:,]? \s* //ix;
  return undef unless $matched;
  return $text;
}

1;

=pod

=over 4

=item describe_conversation

A short (single-word) description for the conversation. For channels that don't
support multiple channels, just the name of the channel is probably fine.

=back
