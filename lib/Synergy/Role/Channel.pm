use v5.24.0;
package Synergy::Role::Channel;

use Moose::Role;
use experimental qw(signatures);
use namespace::clean;

with 'Synergy::Role::HubComponent';

requires qw(
  describe_event

  send_message
  send_message_to_user
);

1;
