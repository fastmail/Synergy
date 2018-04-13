use v5.24.0;
package Synergy::Listener;

use Moose;
use experimental qw(signatures);
use namespace::clean;

has name => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has exclusive => (
  reader  => 'is_exclusive',
  isa     => 'Bool',
  default => 0,
);

has predicate => (
  is  => 'ro',
  isa => 'CodeRef',
  traits  => [ 'Code' ],
  handles => { matches_event => 'execute_method' },
);

has method => (
  is  => 'ro',
  required => 1,
);

no Moose;
1;
