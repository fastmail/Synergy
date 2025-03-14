use v5.36.0;
package Synergy::Reactor::Echo;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

has only_targeted => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

listener echo => async sub ($self, $event) {
  return if $self->only_targeted && ! $event->was_targeted;

  my $from_str = $event->from_user ? $event->from_user->username
                                   : $event->from_address;

  my $response = sprintf 'I heard you, %s. You said "%s"',
    $from_str,
    $event->text;

  $event->mark_handled;
  await $event->reply($response);
};

1;
