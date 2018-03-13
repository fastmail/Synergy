use v5.24.0;
package Synergy::EventHandler::TrivialTest;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  my $response = sprintf 'I heard you, %s. You said "%s"',
    $event->from,
    $event->text;

  $rch->reply($response);

  $main::x++;

  return;
}

1;
