use v5.24.0;
package Synergy::EventHandler::Echo;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;

sub start { }

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  # here, handle LP12345678 & "you're back!"

  return unless $event->was_targeted;

  my $from_str = $event->from_user ? $event->from_user->username
                                   : $event->from_address;

  my $response = sprintf 'I heard you, %s. You said "%s"',
    $from_str,
    $event->text;

  $rch->reply($response);

  $main::x++;

  return 1;
}

1;
