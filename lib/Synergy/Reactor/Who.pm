use v5.24.0;
package Synergy::Reactor::Who;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

sub listener_specs {
  return {
    name      => 'who',
    method    => 'handle_who',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^who/i },
  };
}

sub handle_who ($self, $event, $rch) {
  $event->mark_handled;

  my ($what) = $event->text =~ /^who\s*(.*)/;
  $what =~ s/\s*\?*\z//;

  if ($what =~ /\A\s*(is|are)\s+(you|synergy)\s*\z/) {
    return $event->reply(
      qq!I am Synergy, a holographic computer designed to be the ultimate audio-visual entertainment synthesizer.  I also help out with the timekeeping.!);
  }

  return -1 unless $what =~ s/\A(is|am)\s+//n;

  my $who = $self->resolve_name($what, $event->from_user);
  return $event->reply(qq!I don't know who "$what" is.!) if ! $who;

  my $whois = sprintf "%s (%s)", $who->username, $who->realname;

  if ($what eq $who->username) {
    return $event->reply(qq{"$what" is $whois.});
  }

  $event->reply(qq["$what" is an alias for $whois.]);
}

1;
