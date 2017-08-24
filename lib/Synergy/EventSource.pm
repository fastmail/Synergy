use v5.24.0;
package Synergy::EventSource;

use Moose::Role;
use experimental qw(signatures);
use namespace::clean;

has loop         => (is => 'ro', required => 1);
has eventhandler => (is => 'ro', required => 1);

1;
