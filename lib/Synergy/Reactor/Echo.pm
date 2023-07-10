use v5.32.0;
use warnings;
package Synergy::Reactor::Echo;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

listener echo => async sub ($self, $event) {
  my $from_str = $event->from_user ? $event->from_user->username
                                   : $event->from_address;

  my $response = sprintf 'I heard you, %s. You said "%s"',
    $from_str,
    $event->text;

  $event->mark_handled;
  await $event->reply($response);
};

1;
