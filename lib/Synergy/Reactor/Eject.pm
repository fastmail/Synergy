use v5.24.0;
use warnings;
package Synergy::Reactor::Eject;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first uniq);
use IO::Async::Timer::Countdown;

sub listener_specs {
  return {
    name      => 'warp-core',
    method    => 'handle_eject',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && lc $e->text eq 'eject warp core' },
  };
}

sub handle_eject ($self, $event) {
  $event->mark_handled;
  return $event->reply('only the master user can do that')
    unless $event->from_user && $event->from_user->is_master;

  $event->reply('Good bye.');

  my $timer = IO::Async::Timer::Countdown->new(
    delay => 1,
    on_expire => sub { kill 'INT', $$ },
  );

  $timer->start;

  $self->hub->loop->add($timer);
}

1;
