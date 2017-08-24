use v5.24.0;

package Synergy::ReplyChannel::Stdout;

use Moose;
use namespace::autoclean;

use experimental qw(signatures);

my $i = 0;

sub reply ($self, $text) {
  say $text;
  return;
}

1;
