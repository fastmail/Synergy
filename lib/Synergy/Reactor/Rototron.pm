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
      method    => 'handle_set_availability',
      exclusive => 1,
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^(un)?available\b/in },
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

sub handle_set_availability ($self, $event) {
  $event->mark_handled;

  my ($from, $to);
  my $ymd_re = qr{ ([0-9]{4}) - ([0-9]{2}) - ([0-9]{2}) }x;

  my $adj  = $event->text =~ /\Aun/ ? 'available' : 'unavailable';
  my $text = $event->text =~ s/\A(un)?available\b//rn;
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
      "It's: `$adj on YYYY-MM-DD` "
      . "or `$adj from YYYY-MM-DD to YYYY-MM-DD`"
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

  my $method = qq{set_user_$adj\_on};
  for my $date (@dates) {
    $self->availability_checker->$method(
      $event->from_user->username,
      $date,
    );
  }

  return $event->reply(
    sprintf "I marked you $adj on %s %s.",
      NUMWORDS(0+@dates),
      PL_N('day', 0+@dates),
  );
}

has _duty_cache => (
  is      => 'ro',
  lazy    => 1,
  default => sub {  {}  },
);

sub duties_on ($self, $dt) {
  my $ymd = $dt->ymd;

  my $cached = $self->_duty_cache->{$ymd};

  if (! $cached || (time - $cached->{at} > 900)) {
    my $items = $self->_get_duty_items($ymd);
    return unless $items; # Error.

    $cached->{$ymd} = {
      at    => time,
      items => $self->_get_duty_items($ymd),
    };
  }

  return $cached->{$ymd}{items};
}

sub _get_duty_items ($self, $ymd) {
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
              before      => $ymd . "T00:00:00Z",
              after       => $ymd . "T00:00:00Z",
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

  # Error condition. -- rjbs, 2019-01-31
  return undef unless $res;

  my @events =
    grep {; $want_calendar_id{ $_->{calendarId} } }
    $res->sentence_named('CalendarEvent/get')->as_stripped_pair->[1]{list}->@*;

  return \@events;
}

sub handle_duty ($self, $event) {
  $event->mark_handled;

  my $now = DateTime->now(time_zone => 'UTC');

  my $duties = $self->duties_on($now);

  unless ($duties) {
    return $event->reply("I couldn't get the duty roster!  Sorry.");
  }

  my $reply = "Today's duty roster:\n"
            . join qq{\n}, sort map {; $_->{title} } @$duties;

  $event->reply($reply);
}

1;
