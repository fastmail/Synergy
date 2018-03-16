use v5.24.0;
package Synergy::Reactor::Announce;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use Carp;
use namespace::clean;

has slack_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has announce_chan_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub listener_specs {
  return {
    name      => 'announce',
    method    => 'handle_announce',
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^announce/i },
  };
}

sub start ($self) {
  my $name = $self->slack_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no slack channel named $name, cowardly giving up")
    unless $channel;
}


sub handle_announce ($self, $event, $rch) {
  $event->mark_handled;

  # TODO: remove this once new synergy can sms
  if (0 && $event->from_channel->can('slack')) {
    $rch->reply("wtf, mate? announce it yourself");
    return 1;
  }

  my $to_send = $event->text =~ s/^announce:?\s*//r;

  # XXX fix this
  my $channel_id = $event->from_channel->slack->channel_named($self->announce_chan_name)->{id};

  my $slack = $self->hub->channel_named($self->slack_channel_name);

  my $from = $event->from_user ? $event->from_user->username
                               : $event->from_address;

  $slack->send_text($channel_id, "$from says: $to_send");
}

1;
