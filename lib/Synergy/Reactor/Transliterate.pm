use v5.36.0;
package Synergy::Reactor::Transliterate;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::Util qw(known_alphabets transliterate);

command transliterate => {
  help => '*transliterate to `SCRIPT`: `MESSAGE`*: rewrite a string with a different alphabet',
} => async sub ($self, $event, $rest) {
  my ($alphabet, $text) = $rest =~ /\Ato (\S+): (.+)\z/i;

  unless (defined $alphabet) {
    return await $event->error_reply(
      "Sorry, I didn't understand that.  It's: *transliterate to `SCRIPT`: `MESSAGE`*"
    );
  }

  return await $event->error_reply("Sorry, I don't know that alphabet.")
    unless grep {; lc $_ eq lc $alphabet } known_alphabets;

  $text = transliterate($alphabet, $text);

  await $event->reply("That's: $text");
};

1;
