use v5.24.0;
package Synergy::EventHandler;

use Moose;
use experimental qw(signatures);
use namespace::clean;

use Data::Dumper::Concise;

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  my $response = sprintf 'I heard you, %s. You said "%s"',
    $event->from,
    $event->text;
  $rch->reply($response);
}

1;
