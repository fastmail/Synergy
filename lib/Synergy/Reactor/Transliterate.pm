use v5.24.0;
use warnings;
package Synergy::Reactor::Transliterate;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use Synergy::Util qw(known_alphabets transliterate);

sub listener_specs {
  return {
    name      => 'transliterate',
    method    => 'handle_transliterate',
    exclusive => 1,
    targeted  => 1,
    predicate => sub ($self, $e) { $e->text =~ /\Atransliterate to (\S+):\s+/i },
    help_entries => [
      {
        title => 'transliterate',
        text  => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg
*transliterate to `SCRIPT`: `MESSAGE`*: rewrite a string with a different alphabet
EOH
      },
    ]
  };
}

sub handle_transliterate ($self, $event) {
  $event->mark_handled;

  my ($alphabet, $text) = $event->text =~ /\Atransliterate to (\S+): (.+)\z/i;

  return $event->error_reply("Sorry, I don't know that alphabet.")
    unless grep {; lc $_ eq lc $alphabet } known_alphabets;

  $text = transliterate($alphabet, $text);

  $event->reply("That's: $text");
  return;
}

1;
