use v5.34.0;
use warnings;
package Synergy::Reactor::Transliterate;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::Util qw(known_alphabets transliterate);

command transliterate => {
  help => '*transliterate to `SCRIPT`: `MESSAGE`*: rewrite a string with a different alphabet',
} => async sub ($self, $event, $rest) {
  $event->mark_handled;

  my ($alphabet, $text) = $rest =~ /\Ato (\S+): (.+)\z/i;

  return await $event->error_reply("Sorry, I don't know that alphabet.")
    unless defined $alphabet;

  return await $event->error_reply("Sorry, I don't know that alphabet.")
    unless grep {; lc $_ eq lc $alphabet } known_alphabets;

  $text = transliterate($alphabet, $text);

  await $event->reply("That's: $text");
};

1;
