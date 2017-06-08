use v5.24.0;

package Synergy::ReplyChannel::Test;

use Moose;
use namespace::autoclean;

use experimental qw(signatures);

my $i = 0;

has replies => (
  isa => 'ArrayRef',
  default  => sub {  []  },
  init_arg => undef,
  traits   => [ 'Array' ],
  handles  => {
    reply_count   => 'count',
    record_reply  => 'push',
    clear_replies => 'clear',
    replies       => 'elements',
  },
);

sub reply ($self, $text) {
  $self->record_reply([ $i++, $text ]);
  return;
}

1;
