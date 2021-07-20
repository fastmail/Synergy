use v5.24;
use warnings;
package Synergy::Reactor::Zendesk;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use Date::Parse qw(str2time);
use Future;
use Lingua::EN::Inflect qw(WORDLIST);
use Synergy::Logger '$Logger';
use Time::Duration qw(ago);
use Zendesk::Client;

use experimental qw(postderef signatures);
use namespace::clean;
use utf8;

__PACKAGE__->add_preference(
  name      => 'staff-email-address',
  validator => sub ($self, $value, @) { return $value =~ /@/ ? $value : undef },
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

# This is stolen from the GitLab reactor; I might make this abstract later but
# it'll require a parameterized role. -- michael, 2021-06-18
has _recent_ticket_expansions => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  default => sub { {} },
  handles => {
    has_expanded_ticket_recently => 'exists',
    note_ticket_expansion        => 'set',
    remove_ticket_expansion      => 'delete',
    recent_ticket_expansions     => 'keys',
    ticket_expansion_for         => 'get',
  },
);

# We'll only keep records of expansions for 5m or so.
has expansion_record_reaper => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return IO::Async::Timer::Periodic->new(
      interval => 30,
      on_tick  => sub {
        my $then = time - (60 * 5);

        for my $key ($self->recent_ticket_expansions) {
          my $ts = $self->ticket_expansion_for($key);
          $self->remove_ticket_expansion($key) if $ts lt $then;
        }
      },
    );
  }
);

sub start ($self) {
  $self->hub->loop->add($self->expansion_record_reaper->start);
}

sub listener_specs ($self) {
  my $ticket_re = $self->shorthand_ticket_regex;
  my $url_re = $self->url_ticket_regex;

  return (
    {
      name      => 'mention-ptn',
      method    => 'handle_ptn_mention',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /$ticket_re/;
        return 1 if $e->text =~ /$url_re/;
        return;
      },
    },
  );
}

sub handle_ptn_mention ($self, $event) {
  $event->mark_handled if $event->was_targeted;

  my $ticket_re = $self->shorthand_ticket_regex;
  my @ids = $event->text =~ m/$ticket_re/g;

  my $url_re = $self->url_ticket_regex;
  push @ids, $event->text =~ m/$url_re/g;

  my %ids = map {; $_ => 1 }
            map {; $self->_translate_ticket_id($_) }
            @ids;

  @ids = sort keys %ids;

  my $declined_to_reply = 0;

  my @futures;

  for my $id (@ids) {
      my $key = $self->_expansion_key_for_ticket($event, $id);
      if ($self->has_expanded_ticket_recently($key)) {
        $declined_to_reply++;
        next;
      }

    my $f = $self->_output_ticket($event, $id);
    push @futures, $f;
  }

  my $f = Future->wait_all(@futures);
  $f->retain;

  $f->on_ready(sub ($waiter) {
    $event->ephemeral_reply("I've expanded that recently here; just scroll up a bit.")
      if $declined_to_reply;

    return unless $event->was_targeted;

    my @failed = $waiter->failed_futures;
    my @ids = map {; ($_->failure)[0] } @failed;
    return unless @ids;

    my $which = WORDLIST(@ids, { conj => "or" });
    $event->reply("Sorry, I couldn't find any tickets for $which.");
  });
}

sub _expansion_key_for_ticket ($self, $event, $id) {
  # Not using $event->source_identifier here because we don't care _who_
  # triggered the expansion. -- michael, 2019-02-05
  return join(';',
    $id,
    $event->from_channel->name,
    $event->conversation_address
  );
}

sub _output_ticket ($self, $event, $id) {
  return $self->zendesk_client->ticket_api->get_f($id)
    ->then(sub ($ticket) {
      my $status = $ticket->status;
      my $subject = $ticket->subject;
      my $created = str2time($ticket->created_at);
      my $updated = str2time($ticket->updated_at);

      my $text = "#$id: $subject (status: $status)";

      my $link = sprintf("<https://%s/agent/tickets/%s|#%s>",
        $self->domain,
        $id,
        $id,
      );

      my $assignee = $ticket->assignee;
      my @assignee = $assignee ?  [ "Assigned to" => $assignee->name ] : ();

      my @brand;
      if ( $self->has_brand_mapping && $ticket->brand_id) {
        my $brand_text = $self->brand_mapping->{$ticket->brand_id};
        @brand = [ Product => $brand_text ] if $brand_text;
      }

      my @old_ptn;
      if ($ticket->external_id) {
        @brand = [ "Old PTN" => $ticket->external_id ];
      }

      # slack block syntax is silly.
      my @fields = map {;
        +{
           type => 'mrkdwn',
           text => "*$_->[0]:* $_->[1]",
         }
      } (
        @brand,
        @old_ptn,
        [ "Status"  => ucfirst($status) ],
        [ "Opened"  => ago(time - $created) ],
        [ "Updated" => ago(time - $updated) ],
        @assignee,
      );

      my $blocks = [
        {
          type => "section",
          text => {
            type => "mrkdwn",
            text => "\N{MEMO} $link - $subject",
          }
        },
        {
          type => "section",
          fields => \@fields,
        },
      ];

      $event->reply($text, {
        slack => {
          blocks => $blocks,
          text => $text,
        },
      });

      my $key = $self->_expansion_key_for_ticket($event, $ticket->id);
      $self->note_ticket_expansion($key, time);

      return Future->done(1);
    })
    ->else(sub (@err) {
      $Logger->log([ "error fetching ticket %s from Zendesk", $id ]);
      return Future->fail("PTN $id", 'http');
    });
}

sub ticket_report ($self, $who, $arg = {}) {
  my $email = $self->get_user_preference(
    $who, 'staff-email-address'
  );

  unless ($email) {
    my $text = "ticket_report: (warning) No staff-email-address user pref configured for " . $who->username;
    return Future->done([ $text, { slack => $text } ]);
  }

  $self->zendesk_client
       ->user_api
       ->get_by_email_no_fetch($email)
       ->scoped_client
       ->make_request_f(
         GET => "/api/v2/users/me.json?include=open_ticket_count"
       )->then(sub ($res) {
         unless ($res->{open_ticket_count}) {
           $Logger->log([ "Did not get an open_ticket_count in res: %s", $res ]);
           return Future->fail("ticket_report", 'http');
         }

         # It's a single key/value pair where the key is the id of our user.
         # We just want the value, which is the count
         my ($count) = values $res->{open_ticket_count}->%*;
         return Future->done unless $count;

         my $desc = $arg->{description} // "Zendesk Tickets";
         my $text = sprintf "\N{ADMISSION TICKETS} %s: %s", $desc, $count;

         return Future->done([ $text, { slack => $text } ]);
       })->else(sub (@err) {
         $Logger->log([ "error fetching our user from Zendesk: %s", \@err ]);
         return Future->fail("ticket_report", 'http');
       });
}

sub _filter_count_report ($self, $who, $arg = {}) {
  my $emoji = $arg->{emoji};
  my $desc = $arg->{description} // "Zendesk Tickets";

  my @req;

  if ($arg->{view}) {
    @req = (GET => "/api/v2/views/$arg->{view}/tickets.json");
  } elsif ($arg->{query}) {
    @req = (GET => "/api/v2/search.json?query=" . $arg->{query});
  } else {
    my $text = "Sorry, only view based url reports are supported right now";
    return Future->done([ $text, { slack => $text } ]);
  }

  $self->zendesk_client
       ->make_request_f(
         @req,
       )->then(sub ($res) {
         my $count = $res->{count};
         return Future->done unless $count;

         my $text = "$emoji $desc: $count";

         return Future->done([ $text, { slack => $text } ]);
       })->else(sub (@err) {
         $Logger->log([ "error making request @req to Zendesk: %s", \@err ]);
         return Future->fail("$emoji $desc", 'http');
       });
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
