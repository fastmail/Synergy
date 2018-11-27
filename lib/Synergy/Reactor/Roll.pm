use v5.24.0;
package Synergy::Reactor::Roll;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use Games::Dice qw(roll_array);
use List::Util qw(sum);

sub listener_specs {
  return {
    name      => 'roll',
    method    => 'handle_roll',
    exclusive => 1,
    predicate => sub ($self, $e) {
      $e->was_targeted && $e->text =~ /\Aroll\b/i;
    },
  };
}

sub handle_roll ($self, $event) {
  $event->mark_handled;

  my (undef, $spec) = split /\s+/, $event->text, 2;
  unless ($spec) {
    return $event->reply("usage: roll DICE-SPEC");
  }

  my @rolls = roll_array($spec);
  unless (@rolls) {
    return $event->reply(qq{Sorry, I can't roll those sorts of dice.});
  }

  my $sum = sum @rolls;

  my $result =
    @rolls == 1 ? "@rolls"
                : join(' + ', @rolls) . " = $sum";

  $event->reply("rolled $spec: $result");
}

1;
