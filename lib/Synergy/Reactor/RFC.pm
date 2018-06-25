use v5.24.0;
package Synergy::Reactor::RFC;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'rfc-mention',
    method    => 'handle_rfc',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->text =~ /RFC\s*[0-9]+/i; },
  };
}

sub handle_rfc ($self, $event, $rch) {
  my ($num) = $event->text =~ /RFC\s*([0-9]+)/i;

  my $link = 'https://tools.ietf.org/html/rfc' . $num;

  $rch->reply(
    "RFC $num: $link",
    {
      slack => "<$link|RFC $num>"
    }
  );

  if ($event->was_targeted && $event->text =~ /\A\s* RFC \s* [0-9]+ \s*\z/ix) {
    $event->mark_handled;
  }
}

1;
