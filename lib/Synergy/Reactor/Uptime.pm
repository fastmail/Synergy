use v5.32.0;
use warnings;
package Synergy::Reactor::Uptime;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;

use Synergy::CommandPost;
use List::Util qw(first);
use Time::Duration::Parse;
use Time::Duration;

command uptime => {
  help => 'uptime: Say how long synergy was up for.',
} => async sub ($self, $event, $text) {
  my $uptime = duration(time - $^T);
  await $event->reply("Online for $uptime.");
};

1;
