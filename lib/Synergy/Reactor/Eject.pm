use v5.28.0;
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
    targeted  => 1,
    predicate => sub ($self, $e) { lc $e->text eq 'eject warp core' },
  };
}

sub handle_eject ($self, $event) {
  $event->mark_handled;

  my $f = $event->reply('Good bye.');
  $f->on_done(sub {
    kill 'INT', $$;
  });
}

1;
