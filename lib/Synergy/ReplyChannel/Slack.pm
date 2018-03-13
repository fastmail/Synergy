use v5.24.0;

package Synergy::ReplyChannel::Slack;

use Moose;
use namespace::autoclean;

use experimental qw(signatures);

my $i = 0;

has slack => (
  is => 'ro',
  isa => 'Synergy::External::Slack',
  weak_ref => 1,
  required => 1,
);

has channel => (
  is => 'ro',
  isa => 'Str',
);

sub reply ($self, $text) {
  $self->slack->api_call("chat.postMessage", {
    text => $text,
    channel => $self->channel,
    as_user => 1,
  });
  return;
}

1;
