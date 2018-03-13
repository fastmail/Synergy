use v5.24.0;

package Synergy::ReplyChannel::Callback;

use Moose;
use namespace::autoclean;

use experimental qw(signatures);

has to_reply => (
  isa     => 'CodeRef',
  traits  => [ 'Code' ],
  handles => {
    reply => 'execute_method',
  },
);

1;
