use v5.24.0;
use warnings;
package Synergy::Reactor::Uptime;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);
use Time::Duration::Parse;
use Time::Duration;

sub listener_specs {
  return {
    name      => 'uptime',
    method    => 'handle_uptime',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^(?:uptime|status)\s*$/i },
    help_entries => [
      { title => 'uptime', text => 'uptime: Say how long synergy was up for. Alias: status', },
      { title => 'status', text => 'status: Say how long synergy was up for. Alias: uptime', },
    ],
  };
}

sub handle_uptime ($self, $event) {
  my $uptime = duration(time - $^T);
  $event->reply("Online for $uptime.");
  $event->mark_handled;
}

1;
