use v5.24.0;
package Synergy::EventSource::Slack;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS qw(encode_json decode_json);

use namespace::autoclean;

with 'Synergy::EventSource';

has slack => (
  is => 'ro',
  isa => 'Synergy::External::Slack',
  required => 1,
);

sub BUILD ($self, @) {
  $self->slack->client->{on_frame} = sub ($client, $frame) {
    return unless $frame;

    my $event;
    unless (eval { $event = decode_json($frame) }) {
      warn "ERROR DECODING <$frame> <$@>\n";
      return;
    }

    $self->_handle_slack_event($event);
  };

  $self->slack->connect;
}


sub _handle_slack_event ($self, $e) {
  $self->slack->setup if $e->{type} eq 'hello';
  return unless $e->{type} eq 'message';

  # bots like to talk to each other and never stop
  return if $e->{bot_id};
  return if $self->slack->username($e->{user}) eq 'synergy';

  my $event = Synergy::Event->new({
    type => 'message',
    text => $e->{text},
    from => $self->slack->users->{$e->{user}},
  });

  my $rch = Synergy::ReplyChannel::Slack->new(
    slack => $self->slack,
    channel => $e->{channel},
  );

  $self->eventhandler->handle_event($event, $rch);
}


1;
