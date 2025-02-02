use v5.36.0;
package Synergy::Reactor::Emit;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

command emit => {
  help => "*emit `MESSAGE`*: repeat after me...",
} => async sub ($self, $event, $rest) {
  await $event->reply("$rest", { slack => "$rest" });
};

1;
