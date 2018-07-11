use v5.24.0;
package Synergy::Reactor::RFC;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use JSON ();

sub listener_specs {
  return {
    name      => 'rfc-mention',
    method    => 'handle_rfc',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->text =~ /RFC\s*[0-9]+/i; },
  };
}

has rfc_index_file => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_rfc_index_file',
);

has title_index => (
  reader  => '_title_index',
  isa     => 'HashRef',
  lazy    => 1,
  builder => '_build_title_index',
);

sub _build_title_index ($self, @) {
  return {} unless $self->has_rfc_index_file;

  my $file = $self->rfc_index_file;
  open my $fh, '<', $file or confess("can't open $file for reading: $!");
  my $contents = do { local $/; <$fh> };
  my $index = JSON->new->utf8->decode($contents);

  return $index;
}

sub rfc_title_for ($self, $number) {
  $self->_title_index->{$number};
}

sub handle_rfc ($self, $event) {
  my $text = $event->text;

  my ($num, $link) = $self->extract_rfc($text);

  unless (defined $num && defined $link) {
    if ($event->was_targeted && $event->text =~ /\A\s* RFC \s* [0-9]+/ix) {
      $event->reply("Oddly, I could not figure out what RFC you meant");

      $event->mark_handled;
    }

    return;
  }

  my $title = $self->rfc_title_for($num);

  $event->reply(
    ($title ? "RFC $num: $title\n$link" : "RFC $num - $link"),
    {
      slack => "<$link|RFC $num>" . ($title ? ": $title" : q{})
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
