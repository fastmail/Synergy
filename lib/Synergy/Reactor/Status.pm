use v5.24.0;
package Synergy::Reactor::Status;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);
use Time::Duration::Parse;
use Time::Duration;

sub listener_specs {
  return {
    name      => 'status',
    method    => 'handle_status',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^status(\s|$)/i },
  };
}

sub handle_status ($self, $event, $rch) {
  my $uptime = duration(time - $^T);
  $event->reply("Online for $uptime.");
  $event->mark_handled;
}

1;
