use v5.28.0;
use warnings;
package Synergy::Reactor::Announce;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use Carp;
use namespace::clean;

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

sub listener_specs {
  return {
    name      => 'announce',
    method    => 'handle_announce',
    targeted  => 1,
    predicate => sub ($self, $e) { $e->text =~ /^announce/i },
  };
}

sub start ($self) {
  my $name = $self->to_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no channel named $name, cowardly giving up")
    unless $channel;
}

sub handle_announce ($self, $event) {
  $event->mark_handled;

  if ($event->from_channel->name eq $self->to_channel_name) {
    return $event->error_reply("You're already using the target system!");
  }

  my $to_send = $event->text =~ s/^announce:?\s*//r;

  my $from = $event->from_user ? $event->from_user->username
                               : $event->from_address;

  $self->hub->channel_named($self->to_channel_name)
            ->send_message($self->to_address, "$from says: $to_send");

  return $event->reply("Sent!");
}

1;
