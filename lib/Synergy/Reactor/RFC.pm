use v5.28.0;
use warnings;

package Synergy::Reactor::RFC;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

use utf8;

use DBI;
use JSON::MaybeXS ();
use Synergy::Logger '$Logger';

sub _slink {
  sprintf '<%s%u|RFC %u>', 'https://tools.ietf.org/html/rfc', (0 + $_[0]) x 2
}

sub listener_specs {
  return (
    {
      name      => 'rfc-search',
      method    => 'handle_rfc_search',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) {
        return $e->text =~ /\Arfcs\s+author:[“”"][^"]+[“”"]\z/;
      },
    },
    {
      name      => 'rfc-mention',
      method    => 'handle_rfc',
      predicate => sub ($self, $e) {
        return unless $e->text =~ /(^|\s|\/)RFC\s*[0-9]+/in;
      },
    },
  );
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
  return JSON::MaybeXS->new->decode($json);
}

sub handle_rfc_search ($self, $event) {
  my ($author) = $event->text =~ /\Arfcs\s+author:[“”"]([^"]+)[“”"]\z/;

  my $rows = $self->_dbh->selectall_arrayref(
    "SELECT * FROM rfcs WHERE instr(metadata, ?) > 0 ORDER BY rfc_number",
    { Slice => {} },
    $author,
  );

  my @results;
  for my $row (@$rows) {
    my $data = JSON::MaybeXS->new->decode($row->{metadata});
    next unless grep {; $_ eq $author } $data->{authors}->@*;
    push @results, $data;
  }

  unless (@results) {
    $event->mark_handled;
    return $event->reply("No RFCs found!");
  }

  my $text = join qq{\n}, map {;
    sprintf 'RFC %s - %s, by %s',
      $_->{number},
      $_->{title},
      (join q{, }, $_->{authors}->@*);
  } @results;

  my $slack = join qq{\n}, map {;
    sprintf '%s - %s, by %s',
      _slink($_->{number}),
      $_->{title},
      (join q{, }, $_->{authors}->@*);
  } @results;

  $event->mark_handled;
  $event->reply($text, { slack => $slack });
}

sub handle_rfc ($self, $event) {
  my $text = $event->text;

  my ($num, $link) = $self->extract_rfc($text);

  unless (defined $num && defined $link) {
    if ($event->was_targeted && $event->text =~ /\A\s* RFC \s* [0-9]+/ix) {
      $event->error_reply("Oddly, I could not figure out what RFC you meant");

      $event->mark_handled;
    }

    return;
  }

  my $solo_cmd = $event->was_targeted
              && $event->text =~ /\A\s* RFC \s* [0-9]+ \s*/ix;

  $event->mark_handled if $solo_cmd;

  my $entry = $self->rfc_entry_for($num);
  unless ($entry) {
    $event->error_reply("I'm unable to find an RFC by that number, sorry.");
    return;
  }

  my $title = $entry->{title};

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
             .  (join q{, }, map {; _slink($_) } $entry->{obsoletes}->@*)
             .  "\n";
    }

    if ($entry->{obsoleted_by}->@*) {
      $slack .= "*Obsoleted by:* "
             .  (join q{, }, map {; _slink($_) } $entry->{obsoleted_by}->@*)
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

my $sec_dig = qr/(?:[0-9]+[-.]?)+/;

sub extract_rfc ($self, $text) {
  # match a URL, but not something like "message/rfc822"
  return if $text =~ m{/rfc}i && $text !~ m{\Qtools.ietf.org\E}i;

  return unless $text =~ s/.*RFC\s*([0-9]+)//ig;

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
