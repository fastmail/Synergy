use v5.28.0;
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
    targeted  => 1,
    predicate => sub ($self, $e) { $e->text =~ /^(?:uptime)\s*$/i },
    help_entries => [
      { title => 'uptime', text => 'uptime: Say how long synergy was up for.', },
    ],
  };
}

sub handle_uptime ($self, $event) {
  my $uptime = duration(time - $^T);
  $event->mark_handled;
  $event->reply("Online for $uptime.");
}

1;
