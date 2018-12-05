use v5.24.0;
use warnings;
package Synergy::Listener;

use Moose;
use experimental qw(signatures);
use namespace::clean;

has help_entries => (
  traits  => [ 'Array' ],
  default => sub { [] },
  handles => {
    help_entries => 'elements',
    _add_help_entry => 'push',
  }
);

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

has reactor => (
  is => 'ro',
  weak_ref => 1,
);

no Moose;
1;
