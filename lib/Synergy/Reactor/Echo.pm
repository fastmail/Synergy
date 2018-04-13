use v5.24.0;
package Synergy::Reactor::Echo;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'echo',
    method    => 'echo',
    predicate => sub ($self, $e) { $e->was_targeted },
  };
}

sub echo ($self, $event, $rch) {
  my $from_str = $event->from_user ? $event->from_user->username
                                   : $event->from_address;

  my $response = sprintf 'I heard you, %s. You said "%s"',
    $from_str,
    $event->text;

  $rch->reply($response);
  $event->mark_handled;
}

1;
