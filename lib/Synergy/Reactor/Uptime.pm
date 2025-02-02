use v5.36.0;
package Synergy::Reactor::Uptime;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;

use Synergy::CommandPost;
use Time::Duration;

command uptime => {
  help => 'uptime: Say how long synergy was up for.',
} => async sub ($self, $event, $text) {
  my $uptime = duration(time - $^T);
  await $event->reply("Online for $uptime.");
};

1;
