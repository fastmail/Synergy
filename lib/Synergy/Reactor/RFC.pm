use v5.24.0;
use warnings;

package Synergy::Reactor::RFC;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use DBI;
use JSON ();

sub listener_specs {
  return {
    name      => 'rfc-mention',
    method    => 'handle_rfc',
    predicate => sub ($self, $e) {
      return unless $e->text =~ /RFC\s*[0-9]+/i; },
  };
}

has rfc_index_file => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_rfc_index_file',
);

has _dbh => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my $self = shift;
    my $fn   = $self->rfc_index_file;
    DBI->connect("dbi:SQLite:$fn", undef, undef);
  },
);

sub rfc_entry_for ($self, $number) {
  my ($json) = $self->_dbh->selectrow_array(
    "SELECT metadata FROM rfcs WHERE rfc_number = ?",
    undef,
    $number,
  );

  return unless $json;
  return JSON->new->decode($json);
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

  my $solo_cmd = $event->was_targeted
              && $event->text =~ /\A\s* RFC \s* [0-9]+ \s*/ix;

  $event->mark_handled if $solo_cmd;

  my $entry = $self->rfc_entry_for($num);
  unless ($entry) {
    $event->reply("I'm unable to find an RFC by that number, sorry.");
    return;
  }

  my $title = $entry->{title};

  my $slink = sub {
    sprintf '<%s%u|RFC %u>', 'https://tools.ietf.org/html/rfc', (0 + $_[0]) x 2
  };

  my $slack = sprintf('<%s|RFC %u>', $link, $num) . ($title ? ": $title" : q{});

  if ($solo_cmd) {
    $slack .= "\n";
    $slack .= "*Published:* $entry->{date}\n";
    $slack .= "*Status:* $entry->{status}\n";
    if ($entry->{authors}->@*) {
      $slack .= "*Authors:* "
             .  (join q{, }, $entry->{authors}->@*)
             .  "\n";
    }

    if ($entry->{obsoletes}->@*) {
      $slack .= "*Obsoletes:* "
             .  (join q{, }, map {; $slink->($_) } $entry->{obsoletes}->@*)
             .  "\n";
    }

    if ($entry->{obsoleted_by}->@*) {
      $slack .= "*Obsoleted by:* "
             .  (join q{, }, map {; $slink->($_) } $entry->{obsoleted_by}->@*)
             .  "\n";
    }

    $slack .= "\n$entry->{abstract}" if $entry->{abstract};
  }

  chomp $slack;

  $event->reply(
    ($title ? "RFC $num: $title\n$link" : "RFC $num - $link"),
    {
      slack => $slack,
    }
  );
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
