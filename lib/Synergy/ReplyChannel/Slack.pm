use v5.24.0;

package Synergy::ReplyChannel::Slack;

use Moose;
use namespace::autoclean;

use experimental qw(signatures);

my $i = 0;

has slack => (
  is => 'ro',
  isa => 'Synergy::External::Slack',
  required => 1,
);

sub reply ($self, $text) {
  say "(on slack) $text";
  return;
}

1;
