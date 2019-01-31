use v5.24.0;
use warnings;
package Synergy::Reactor::Rototron;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use JMAP::Tester;
use JSON::MaybeXS;
use Lingua::EN::Inflect qw(NUMWORDS PL_N);
use Synergy::Logger '$Logger';
use Synergy::Rototron;
use Synergy::Util qw(parse_date_for_user);

sub listener_specs {
  return (
    {
      name      => 'duty',
      method    => 'handle_duty',
      exclusive => 1,
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^duty$/i },
    },
    {
      name      => 'unavailable',
      method    => 'handle_unavailable',
      exclusive => 1,
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^unavailable\b/i },
    },
  );
}

has roto_config_path => (
  is => 'ro',
  required => 1,
);

has roto_config => (
  is   => 'ro',
  lazy => 1,

  default => sub ($self, @) {
    my $fn = $self->roto_config_path;
    open my $fh, '<', $fn or die "can't read $fn: $!";
    my $json = do { local $/; <$fh> };
    JSON::MaybeXS->new->utf8(1)->decode($json);
  }
);

has availability_db_path => (
  is => 'ro',
  required => 1,
);

has availability_checker => (
  is => 'ro',
  lazy => 1,
  default => sub ($self, @) {
    return Synergy::Rototron::AvailabilityChecker->new({
      db_path => $self->availability_db_path,
    });
  },
);

has jmap_client => (
  is   => 'ro',
  lazy => 1,
  default => sub ($self, @) {
    return Synergy::Rototron::JMAPClient->new({
      api_uri  => $self->roto_config->{jmap}{api_uri},
      username => $self->roto_config->{jmap}{username},
      password => $self->roto_config->{jmap}{password},
    });
  },
);

after register_with_hub => sub ($self, @) {
  $self->roto_config; # crash early, crash often -- rjbs, 2019-01-31
};

sub handle_unavailable ($self, $event) {
  $event->mark_handled;

  my ($from, $to);
  my $ymd_re = qr{ ([0-9]{4}) - ([0-9]{2}) - ([0-9]{2}) }x;

  my $text = $event->text =~ s/\Aunavailable\b//r;
  $text =~ s/\A\s+//;

  if ($text =~ m{\Aon\s+($ymd_re)\z}) {
    $from = parse_date_for_user("$1", $event->from_user);
    $to   = $from->clone;
  } elsif ($text =~ m{\Afrom\s+($ymd_re)\s+to\s+($ymd_re)\z}) {
    my ($d1, $d2) = ($1, $2);
    $from = parse_date_for_user($d1, $event->from_user);
    $to   = parse_date_for_user($d2, $event->from_user);
  } else {
    return $event->reply(
      "It's: `unavailable on YYYY-MM-DD` "
      . "or `unavailable from YYYY-MM-DD to YYYY-MM-DD`"
    );
  }

  $from->truncate(to => 'day');
  $to->truncate(to => 'day');

  my @dates;
  until ($from > $to) {
    push @dates, $from;
    $from->add(days => 1);
  }

  unless (@dates) { return $event->reply("That range didn't make sense."); }
  if (@dates > 28) { return $event->reply("That range is too large."); }

  for my $date (@dates) {
    $self->availability_checker->set_user_unavailable_on(
      $event->from_user->username,
      $date,
    );
  }

  return $event->reply(
    sprintf "I marked you unavailable on %s %s.",
      NUMWORDS(0+@dates),
      PL_N('day', 0+@dates),
  );
}

sub handle_duty ($self, $event) {
  $event->mark_handled;

  my $now = DateTime->now(time_zone => 'UTC');

  my %want_calendar_id = map {; $_->{calendar_id} => 1 }
                         values $self->roto_config->{rotors}->%*;

  my $res = eval {
    my $res = $self->jmap_client->request({
      using       => [ 'urn:ietf:params:jmap:mail' ],
      methodCalls => [
        [
          'CalendarEvent/query' => {
            filter => {
              inCalendars => [ keys %want_calendar_id ],
              before      => $now->ymd . "T00:00:00Z",
              after       => $now->ymd . "T00:00:00Z",
            },
          },
          'a',
        ],
        [
          'CalendarEvent/get' => { '#ids' => {
            resultOf => 'a',
            name => 'CalendarEvent/query',
            path => '/ids',
          } }
        ],
      ]
    });

    $res->assert_successful;
    $res;
  };

  unless ($res) {
    return $event->reply("Sorry, I couldn't get the duty roster.");
  }

  my @events =
    grep {; $want_calendar_id{ $_->{calendarId} } }
    $res->sentence_named('CalendarEvent/get')->as_stripped_pair->[1]{list}->@*;

  my $reply = "Today's duty roster:\n"
            . join qq{\n}, sort map {; $_->{title} } @events;

  $event->reply($reply);
}

1;
