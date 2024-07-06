use v5.32.0;
package Synergy::Reactor::Zendesk;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::DeduplicatesExpandos' => {
       expandos => [ 'ticket' ],
     };

use experimental qw(postderef signatures);
use namespace::clean;
use utf8;

use Date::Parse qw(str2time);
use Future;
use Future::AsyncAwait;
use Lingua::EN::Inflect qw(WORDLIST);
use Slack::BlockKit::Sugar -all => { -prefix => 'bk_' };
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Time::Duration qw(ago);
use Try::Tiny;
use Zendesk::Client;
use Synergy::Logger '$Logger';

__PACKAGE__->add_preference(
  name      => 'staff-email-address',
  validator => async sub ($self, $value, @) { return $value =~ /@/ ? $value : undef },
  description => 'Your staff email address in Zendesk',
);

has [qw( domain username api_token )] => (
  is => 'ro',
  required => 1,
);

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

# XXX config'able
has shorthand_ticket_regex => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $prefix = 'PTN';
    return qr/(?:^|\W)(?:#|(?i)$prefix)\s*[_*]{0,2}([0-9]{5,})\b/i;
  },
);

has url_ticket_regex => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $domain = $self->domain;
    return qr{\bhttps://$domain/agent/tickets/([0-9]{7,})\b}i;
  },
);

# id => name-or-slackmoji
has brand_mapping => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_brand_mapping',
);

has zendesk_client => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $username = $self->username;
    $username .= '/token' unless $username =~ m{/token$};

    return Zendesk::Client->new({
      username => $username,
      domain   => $self->domain,
      token    => $self->api_token,
    });
  },
);

has ticket_mapping_dbfile => (
  is => 'ro',
  isa => 'Str',
  default => "ticket-mapping.sqlite",
);

has _ticket_mapping_dbh => (
  is  => 'ro',
  lazy     => 1,
  init_arg => undef,
  default  => sub ($self, @) {
    my $dbf = $self->ticket_mapping_dbfile;

    my $dbh = DBI->connect(
      "dbi:SQLite:dbname=$dbf",
      undef,
      undef,
      { RaiseError => 1 },
    );

    {
      no warnings 'once';
      die $DBI::errstr unless $dbh;
    }

    $dbh->do(q{
      CREATE TABLE IF NOT EXISTS ticket_mapping (
        helpspot_id INTEGER PRIMARY KEY,
        zendesk_id INTEGER NOT NULL
      );
    });

    return $dbh;
  },
);

listener ptn_mention => async sub ($self, $event) {
  my $ticket_re = $self->shorthand_ticket_regex;
  my @ids = $event->text =~ m/$ticket_re/g;

  my $url_re = $self->url_ticket_regex;
  push @ids, $event->text =~ m/$url_re/g;

  return unless @ids;

  $event->mark_handled if $event->was_targeted;

  my %ids = map {; $_ => 1 }
            map {; $self->_translate_ticket_id($_) }
            @ids;

  @ids = sort keys %ids;

  my $declined_to_reply = 0;

  my @futures;

  for my $id (@ids) {
    if ($self->has_expanded_ticket_recently($event, $id)) {
      $declined_to_reply++;
      next;
    }

    my $f = $self->_output_ticket($event, $id);
    push @futures, $f;
  }

  await Future->wait_all(@futures);

  $event->ephemeral_reply("I've expanded that recently here; just scroll up a bit.")
    if $declined_to_reply;

  return unless $event->was_targeted;

  if (my @failed = grep {; $_->is_failed } @futures) {
    my @ids = map  {; ($_->failure)[0] } @failed;
    return unless @ids;

    my $which = WORDLIST(@ids, { conj => "or" });
    return await $event->reply("Sorry, I couldn't find any tickets for $which.");
  }

  return;
};

async sub _output_ticket ($self, $event, $id) {
  my $ticket;

  my $ok = eval {
    $ticket = await $self->zendesk_client->ticket_api->get_f($id);
    1;
  };

  unless ($ok) {
    my $error = $@;
    $Logger->log([ "error fetching ticket %s from Zendesk", $id ]);
    return Future->fail("PTN $id", 'http');
  };

  my $status = $ticket->status;
  my $subject = $ticket->subject;
  my $created = str2time($ticket->created_at);
  my $updated = str2time($ticket->updated_at);

  my $text = "#$id: $subject (status: $status)";

  my $assignee = $ticket->assignee;
  my @assignee = $assignee ?  [ "Assigned to" => $assignee->name ] : ();

  my @brand;
  if ($self->has_brand_mapping && $ticket->brand_id) {
    my $brand_text = $self->brand_mapping->{$ticket->brand_id};
    @brand = [ Product => $brand_text ] if $brand_text;
  }

  my @old_ptn;
  if ($ticket->external_id) {
    @old_ptn = [ "Old PTN" => $ticket->external_id ];
  }

  # It would be nicer to use rich text, because *...* can be ambiguous if the
  # enclosed thing has mrkdwn -- but we know this won't!  And also, you can't
  # use anything but plain_text or mrkdwn in the "fields" of a section, and we
  # want that for the two-column display. -- rjbs, 2024-07-05
  my @fields = map {; bk_mrkdwn("*$_->[0]:* $_->[1]") } (
    @brand,
    @old_ptn,
    [ "Status"  => ucfirst($status) ],
    [ "Opened"  => ago(time - $created) ],
    [ "Updated" => ago(time - $updated) ],
    @assignee,
  );

  my $blocks = bk_blocks(
    bk_richblock(
      bk_richsection(
        bk_emoji('memo'),
        " ",
        bk_link(
          sprintf("<https://%s/agent/tickets/%s", $self->domain, $id),
          "PTN $id",
        ),
        " - $subject",
      ),
    ),
    bk_section({ fields => \@fields }),
  );

  $self->note_ticket_expansion($event, $ticket->id);

  return await $event->reply($text, {
    slack => {
      blocks => $blocks->as_struct,
      text => $text,
    },
  });
}

async sub ticket_report ($self, $who, $arg = {}) {
  my $email = $self->get_user_preference(
    $who, 'staff-email-address'
  );

  unless ($email) {
    my $text = "ticket_report: (warning) No staff-email-address user pref configured for " . $who->username;
    return [ $text, { slack => $text } ];
  }

  # Return if $email has no associated Zendesk account
  my $user = eval {
    await $self->zendesk_client->user_api->get_by_email_f($email);
  };

  if ($@) {
    my $error = $@;
    $error =~ /Expected 1 user, got 0/
              ? $Logger->log([
                  "No Zendesk user found for %s",
                  $email,
                ])
              : $Logger->log([
                  "Unknown error trying to get Zendesk user for %s: %s",
                  $email,
                  $error,
                ]);
    return;
  };

  my $res;
  my $ok = eval {
    $res = await $user->scoped_client
                      ->make_request_f(
                        GET => "/api/v2/users/me.json?include=open_ticket_count"
                      );
    1;
  };

  unless ($ok) {
    my $error = $@;
    $Logger->log([ "error fetching our user from Zendesk: %s", $error ]);
    return [ "failed to get tickets for ticket report" ];
  };

  unless ($res->{open_ticket_count}) {
    $Logger->log([ "Did not get an open_ticket_count in res: %s", $res ]);
    return [ "couldn't get open ticket count for ticket report" ];
  }

  # It's a single key/value pair where the key is the id of our user.
  # We just want the value, which is the count
  my ($count) = values $res->{open_ticket_count}->%*;
  return unless $count;

  my $desc = $arg->{description} // "Zendesk Tickets";
  my $text = sprintf "\N{ADMISSION TICKETS} %s: %s", $desc, $count;

  return [ $text, { slack => $text } ];
}

async sub _filter_count_report ($self, $who, $arg = {}) {
  my $emoji = $arg->{emoji};
  my $desc = $arg->{description} // "Zendesk Tickets";

  my @req;

  if ($arg->{view}) {
    @req = (GET => "/api/v2/views/$arg->{view}/tickets.json");
  } elsif ($arg->{query}) {
    @req = (GET => "/api/v2/search.json?query=" . $arg->{query});
  } else {
    my $text = "Sorry, only view based url reports are supported right now";
    return [ $text, { slack => $text } ];
  }

  my $res;
  my $ok = eval {
    $res = $self->zendesk_client->make_request_f(@req);
    1;
  };

  unless ($ok) {
    my $error = $@;
    $Logger->log([ "error making request %s to Zendesk: %s", \@req, $error ]);
    die "failed to get filter count report content";
  };

  my $count = $res->{count};
  return unless $count;

  my $text = "$emoji $desc: $count";

  return [ $text, { slack => $text } ];
}

sub unassigned_bug_report ($self, $who, $arg = {}) {
  $arg->{description} //= "Unassigned bug reports";
  $arg->{emoji}       //= "\N{BUG}";

  $self->_filter_count_report($who, $arg);
}

sub _translate_ticket_id ($self, $id) {
  return $id if $id >= 1_000_000;

  my ($zd_id) = $self->_ticket_mapping_dbh->selectrow_array(
    "SELECT zendesk_id from ticket_mapping WHERE helpspot_id = ?",
    undef,
    "$id",
  );

  return $zd_id if $zd_id;
  return $id;
}

1;
