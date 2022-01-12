use v5.28.0;
use warnings;
package Synergy::Reactor::Who;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

sub listener_specs {
  return {
    name      => 'who',
    method    => 'handle_who',
    exclusive => 1,
    targeted  => 1,
    predicate => sub ($self, $e) { $e->text =~ /^who/i },
  };
}

sub handle_who ($self, $event) {
  my ($what) = $event->text =~ /^who\s*(.*)/i;
  $what =~ s/\s*\?*\z//;

  if ($what =~ /\A\s*(is|are)\s+(you|synergy)\s*\z/) {
    $event->mark_handled;

    return $event->reply(
      qq!I am Synergy, a holographic computer designed to be the ultimate audio-visual entertainment synthesizer.  I also help out with the timekeeping.!);
  }

  return unless $what =~ s/\A(is|am)\s+//n;

  $event->mark_handled;

  my $who = $self->resolve_name($what, $event->from_user);
  return $event->error_reply(qq!I don't know who "$what" is!) if ! $who;

  my $whois = sprintf "%s (%s)", $who->username, $who->realname;

  my $text = $what eq $who->username
           ? qq{"$what" is $whois.}
           : qq["$what" is an alias for $whois.];

  if ($who->preference('pronoun')) {
    $text .= sprintf ' (%s/%s)', $who->they, $who->them;
  }

  $event->reply($text);
}

1;
