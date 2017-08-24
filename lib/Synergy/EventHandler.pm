use v5.24.0;
package Synergy::EventHandler;

use Moose;
use experimental qw(signatures);
use namespace::clean;

use Data::Dumper::Concise;

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  $rch->reply("I got your message: " . $event->text);
}

1;
