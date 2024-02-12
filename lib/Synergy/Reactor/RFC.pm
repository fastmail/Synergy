use v5.32.0;
use warnings;

package Synergy::Reactor::RFC;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use utf8;

use DBI;
use Future::AsyncAwait;
use JSON::MaybeXS ();
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(reformat_help);
use XML::LibXML;

sub _slink {
  sprintf '<https://www.rfc-editor.org/rfc/rfc%u.html|RFC %u>', (0 + $_[0]) x 2
}

has rfc_index_file => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_rfc_index_file',
);

sub _dbh ($self) {
  my $fn = $self->rfc_index_file;
  DBI->connect("dbi:SQLite:$fn", undef, undef);
}

sub rfc_entry_for ($self, $number) {
  my ($json) = $self->_dbh->selectrow_array(
    "SELECT metadata FROM rfcs WHERE rfc_number = ?",
    undef,
    $number,
  );

  return unless $json;
  return JSON::MaybeXS->new->decode($json);
}

responder update_index => {
  help => "*update rfc index*: rebuild the RFC index from the IETF copy",
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($self, $text, @) {
    if ($text =~ /\Aupdate rfc index\z/i) {
      return [ ];
    }

    return;
  },
} => async sub ($self, $event) {
  $event->mark_handled;

  my $index_res = await $self->hub->http_get(
    "https://www.ietf.org/rfc/rfc-index.xml",
  );

  unless ($index_res->is_success) {
    $Logger->log([ "failed to get RFC index: %s", $index_res->status_line ]);
    return $event->error_reply(q{I couldn't get the RFC index to update!});
  }

  my $doc = eval {
    XML::LibXML->load_xml(string => $index_res->decoded_content(charset => undef));
  };

  unless ($doc) {
    $Logger->log([ "error parsing RFC index: %s", $@ ]);
    return $event->error_reply(q{I couldn't parse the RFC index, sorry.});
  }

  my $new_dbh = DBI->connect("dbi:SQLite:dbname=:memory:", undef, undef);

  $new_dbh->do(
    "CREATE TABLE rfcs (
      rfc_number integer not null primary key,
      metadata   text not null
    )"
  ) or die "can't create table";

  my $JSON = JSON::MaybeXS->new->canonical;

  my sub element_text {
    my ($start_elem, $name) = @_;

    my ($want_elem)  = $start_elem->getElementsByTagName($name);
    return unless $want_elem;
    return $want_elem->textContent;
  }

  my $xc = XML::LibXML::XPathContext->new;
  $xc->registerNs('rfc', 'http://www.rfc-editor.org/rfc-index');

  $event->reply("Okay, I'm working on indexing the new RFC index.");

  my $rfcs = $xc->findnodes('//rfc:rfc-entry', $doc);
  for my $rfc ($rfcs->get_nodelist) {
    my ($doc_id) = $xc->findvalue('rfc:doc-id/text()', $rfc);
    my ($title)  = $xc->findvalue('rfc:title/text()', $rfc);
    my @authors  = map {; "$_" }
                   $xc->findnodes('rfc:author/rfc:name/text()', $rfc);
    my ($abstract) = $xc->findvalue('rfc:abstract/*/text()', $rfc);

    my $year  = $xc->findvalue('rfc:date/rfc:year/text()', $rfc);
    my $month = $xc->findvalue('rfc:date/rfc:month/text()', $rfc);

    my @obs = map  {; 0+$_ }
              grep {; s/^RFC// }
              map  {; "$_" }
              $xc->findnodes('rfc:obsoletes/rfc:doc-id/text()', $rfc);

    my @obs_by = map  {; 0+$_ }
                 grep {; s/^RFC// }
                 map  {; "$_" }
                 $xc->findnodes('rfc:obsoleted-by/rfc:doc-id/text()', $rfc);

    my $status = $xc->findvalue('rfc:current-status/text()', $rfc);

    # updated-by/doc-id
    # current-status

    my $number   = 0 + ($doc_id =~ s/^RFC//r);
    my %metadata = (
      abstract => $abstract,
      authors  => \@authors,
      date     => "$month $year",
      number   => 0+$number,
      status   => $status,
      title    => $title,
      obsoletes     => [ sort {; $a <=> $b } @obs ],
      obsoleted_by  => [ sort {; $a <=> $b } @obs_by ],
    );

    $new_dbh->do(
      "INSERT INTO rfcs (rfc_number, metadata) VALUES (?, ?)",
      undef,
      0+$number,
      $JSON->encode(\%metadata)
    );
  }

  $self->_dbh->sqlite_backup_from_dbh($new_dbh);

  return await $event->reply("Indexing complete!");
};

command rfcs => {
  help => reformat_help(<<~'EOH'),
    *rfcs*: search through the RFCs

    Right now, there's only one way to search: `author:"J. Smith"`.
    EOH
} => async sub ($self, $event, $rest) {
  my ($author) = $rest =~ /\Aauthor:[“”"]([^"]+)[“”"]\z/;

  unless ($author) {
    return await $event->error_reply("I don't know how to search for that!");
  }

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
    return await $event->error_reply("No RFCs found!");
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

  return await $event->reply($text, { slack => $slack });
};

listener rfc_mention => async sub ($self, $event) {
  my $text = $event->text;

  my ($num, $link) = $self->extract_rfc($text);

  unless (defined $num && defined $link) {
    if ($event->was_targeted && $event->text =~ /\A\s* RFC \s* [0-9]+/ix) {
      $event->mark_handled;
      return await $event->error_reply("Oddly, I could not figure out what RFC you meant");
    }

    return;
  }

  my $solo_cmd = $event->was_targeted
              && $event->text =~ /\A\s* RFC \s* [0-9]+ \s*/ix;

  $event->mark_handled if $solo_cmd;

  my $entry = $self->rfc_entry_for($num);
  unless ($entry) {
    return await $event->error_reply("I'm unable to find an RFC by that number, sorry.");
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

  return await $event->reply(
    ($title ? "RFC $num: $title\n$link" : "RFC $num - $link"),
    {
      slack => $slack,
    }
  );
};

command maxrfc => {
  help => "**maxrfc**: get the highest indexed RFC in our RFC index",
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->error_reply("Sorry, maxrfc doesn't take any arguments.");
  }

  my ($row) = $self->_dbh->selectrow_hashref(q{
    SELECT *
    FROM rfcs
    ORDER BY rfc_number DESC
    LIMIT 1
  });

  my $data = JSON::MaybeXS->new->decode($row->{metadata});

  my $reply = sprintf "The highest-numbered RFC in our index is RFC%s, %s.",
    $row->{rfc_number},
    $data->{title};

  return await $event->reply($reply);
};

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

  my $link = "https://www.rfc-editor.org/rfc/rfc$num.html";

  if ($section) {
    $link .= "#section-$section";
  }

  return ($num, $link);
}

1;
