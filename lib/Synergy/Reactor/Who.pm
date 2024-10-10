use v5.32.0;
use warnings;
package Synergy::Reactor::Who;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use DateTime;
use Future::AsyncAwait;
use List::Util qw(first);
use Synergy::CommandPost;

command who => {
  help => '*who is NAME*: get details on another Synergy user named NAME',
} => async sub ($self, $event, $rest) {
  $rest =~ s/\s*\?*\z//;

  if ($rest =~ /\A\s*(is|are)\s+(you|synergy)\s*\z/n) {
    return await $event->reply(
      qq!I am Synergy, a holographic computer designed to be the ultimate audio-visual entertainment synthesizer.  I also help out with the timekeeping.!
    );
  }

  unless ($rest =~ s/\A(is|am)\s+//n) {
    return await $event->reply_error("Sorry, I don't understand what you want to know.");
  }

  my $who = $self->resolve_name($rest, $event->from_user);

  unless ($who) {
    return await $event->error_reply(qq!I don't know who "$rest" is.!);
  }

  my $whois = sprintf "%s (%s)", $who->username, $who->realname;

  my $text = $rest eq $who->username
           ? qq{"$rest" is $whois.}
           : qq["$rest" is an alias for $whois.];

  if ($who->preference('pronoun')) {
    $text .= sprintf ' (%s/%s)', $who->they, $who->them;
  }

  await $event->reply($text);
};

1;
