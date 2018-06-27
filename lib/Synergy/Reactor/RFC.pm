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
  my $text = $event->text;

  my ($num, $link) = $self->extract_rfc($text);

  unless (defined $num && defined $link) {
    if ($event->was_targeted && $event->text =~ /\A\s* RFC \s* [0-9]+/ix) {
      $rch->reply("Oddly, I could not figure out what RFC you meant");

      $event->mark_handled;
    }

    return;
  }

  $rch->reply(
    "RFC $num: $link",
    {
      slack => "<$link|RFC $num>"
    }
  );

  if ($event->was_targeted && $event->text =~ /\A\s* RFC \s* [0-9]+ \s*/ix) {
    $event->mark_handled;
  }
}

my $sec_dig = qr/[0-9]+(?:[.-])?(?:[0-9]+)?/;

sub extract_rfc ($self, $text) {
  return unless $text =~ s/RFC\s*([0-9]+)//ig;

  my $num = $1;

  my $section;

  if ($text =~ /^\s*#($sec_dig)/g) {
    $section = $1;
  } elsif ($text =~ /^\s*#?section\s*#?\s*($sec_dig)/g) {
    $section = $1;
  }

  $section =~ s/-/./ if $section;

  my $link = 'https://tools.ietf.org/html/rfc' . $num;

  if ($section) {
    $link .= "#section-$section";
  }

  return ($num, $link);
}

1;
