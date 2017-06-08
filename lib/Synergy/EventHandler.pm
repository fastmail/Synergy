use v5.24.0;
package Synergy::EventHandler;

use Moose;
use experimental qw(signatures);
use namespace::clean;

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  my $rand = rand 5;
  $rch->reply("I got your message ($_).") for (0 .. $rand);
}

1;
