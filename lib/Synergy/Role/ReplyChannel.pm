use v5.24.0;
package Synergy::Role::ReplyChannel;

use Moose::Role;
use experimental qw(signatures);
use namespace::clean;

requires 'reply';
requires 'is_private';

1;
