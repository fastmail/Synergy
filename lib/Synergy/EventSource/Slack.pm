use v5.24.0;
package Synergy::EventSource::Slack;

use Moose;
use experimental qw(signatures);
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

  my $event = Synergy::Event->new({
    type => 'message',
    text => $e->{text},
  });
}


1;
