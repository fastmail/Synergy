use v5.24.0;
package Synergy::EventHandler::Echo;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;

sub start { }

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  my $rn;

  if ($event->user) {
    $rn = "%s, (" . $event->user->realname . ")";
  } else {
    $rn = "%s";
  }

  my $response = sprintf "I heard you, $rn. You said \"%s\"",
    $event->from,
    $event->text;

  $rch->reply($response);

  return 1;
}

1;
