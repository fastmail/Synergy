use v5.24.0;
use warnings;
package Synergy::Reactor::Transliterate;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use Synergy::Util qw(known_alphabets transliterate);

sub listener_specs {
  return {
    name      => 'transliterate',
    method    => 'handle_transliterate',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->was_targeted;
      return 1 if $e->text =~ /\Atransliterate to (\S+):\s+/i;
      return;
    },
  };
}

sub handle_transliterate ($self, $event) {
  $event->mark_handled;

  my ($alphabet, $text) = $event->text =~ /\Atransliterate to (\S+): (.+)\z/;

  $event->reply_error("Sorry, I don't know that alphabet.")
    unless grep {; lc $_ eq lc $alphabet } known_alphabets;

  $text = transliterate($alphabet, $text);

  $event->reply("That's: $text");
  return;
}

1;
