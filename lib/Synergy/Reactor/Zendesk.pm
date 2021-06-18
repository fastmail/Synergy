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

has [qw( domain username api_token )] => (
  is => 'ro',
  required => 1,
);

# XXX config'able
has ticket_regex => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $prefix = 'PTN';
    return qr/(?:^|\W)(?:#|(?i)$prefix)\s*[_*]{0,2}([0-9]{7,})\b/i;
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

sub listener_specs ($self) {
  my $ticket_re = $self->ticket_regex;

  return (
    {
      name      => 'mention-ptn',
      method    => 'handle_ptn_mention',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /$ticket_re/;
        return;
      },
    },
  );
}

sub handle_ptn_mention ($self, $event) {
  $event->mark_handled if $event->was_targeted;

  my $ticket_re = $self->ticket_regex;
  my @ids = $event->text =~ m/$ticket_re/g;
  my %ids = map {; $_ => 1 } @ids;
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

      my $text = "#%$id: $subject (status: $status)";

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

      # slack block syntax is silly.
      my @fields = map {;
        +{
           type => 'mrkdwn',
           text => "*$_->[0]:* $_->[1]",
         }
      } (
        @brand,
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

1;
