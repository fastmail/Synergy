use v5.28.0;
use warnings;
package Synergy::Reactor::Emit;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'emit',
    method    => 'handle_emit',
    exclusive => 1,
    targeted  => 1,
    predicate => sub ($self, $e) { $e->text =~ /\Aemit(?:\s+.+)?/i },
  };
}

sub handle_emit ($self, $event) {
  my (undef, $text) = split /\s+/, $event->text, 2;

  $event->reply("$text", { slack => "$text" });
  $event->mark_handled;
}

1;
