use v5.24.0;
package Synergy::Role::Listener;

use Moose::Role;
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
  isa => 'Code',
  traits  => [ 'Code' ],
  handles => { matches_event => 'execute_method' },
);

has reactor_method => (
  is  => 'ro',
  required => 1,
);

no Moose::Role;
1;
