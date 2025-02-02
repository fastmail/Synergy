use v5.36.0;
package Synergy::Role::ProvidesUserStatus;

use Moose::Role;

use namespace::clean;

requires 'user_status_for';

no Moose::Role;
1;
