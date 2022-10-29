use v5.34.0;
use warnings;
package Synergy::Reactor::Emit;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

command emit => {
} => async sub ($self, $event, $rest) {
  $event->mark_handled;
  await $event->reply("$rest", { slack => "$rest" });
};

1;
