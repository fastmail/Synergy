use v5.24.0;
use warnings;
package Synergy::Reactor::Eject;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

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

  my $f = $event->reply('Good bye.');
  $f->on_done(sub {
    kill 'INT', $$;
  });
}

1;
