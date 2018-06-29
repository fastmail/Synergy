use v5.24.0;
package Synergy::Reactor::Emit;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'emit',
    method    => 'handle_emit',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->was_targeted;
      return unless $e->text =~ /\Aemit(?:\s+.+)?/; },
  };
}

sub handle_emit ($self, $event, $rch) {
  my (undef, $text) = split /\s+/, $event->text, 2;

  $event->reply("$text", { slack => "$text" });
  $event->mark_handled;
}

1;
