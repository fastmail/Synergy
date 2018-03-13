use v5.24.0;
package Synergy::Role::EventHandler;

use Moose::Role;
use experimental qw(signatures);
use namespace::clean;

requires 'handle_event';

no Moose::Role;
1;
