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
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^duty(?:\s|$)/i },
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

has rototron => (
  is    => 'ro',
  lazy  => 1,
  handles => [ qw(availability_checker jmap_client) ],
  default => sub ($self, @) {
    return Synergy::Rototron->new({
      config_path => $self->roto_config_path,
    });
  },
);

after register_with_hub => sub ($self, @) {
  $self->rototron; # crash early, crash often -- rjbs, 2019-01-31
};

sub handle_set_availability ($self, $event) {
  $event->mark_handled;

  my ($from, $to);
  my $ymd_re = qr{ [0-9]{4} - [0-9]{2} - [0-9]{2} }x;

  my $adj  = $event->text =~ /\Aun/ ? 'unavailable' : 'available';
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
    push @dates, $from->clone;
    $from->add(days => 1);
  }

  unless (@dates) { return $event->error_reply("That range didn't make sense."); }
  if (@dates > 28) { return $event->error_reply("That range is too large."); }

  my $method = qq{set_user_$adj\_on};
  for my $date (@dates) {
    $self->availability_checker->$method(
      $event->from_user->username,
      $date,
    );
  }

  $event->reply(
    sprintf "I marked you $adj on %s %s.",
      NUMWORDS(0+@dates),
      PL_N('day', 0+@dates),
  );

  $self->_replan_range($dates[0], $dates[-1]);
}

sub _replan_range ($self, $from_dt, $to_dt) {
  my $plan = $self->rototron->compute_rotor_update($from_dt, $to_dt);

  $Logger->log([ 'replan plan %s - %s: %s', $from_dt, $to_dt, $plan ]);
  return unless $plan;

  my $res = $self->rototron->jmap_client->request({
    using       => [ 'urn:ietf:params:jmap:mail' ],
    methodCalls => [
      [ 'CalendarEvent/set' => $plan, ],
    ],
  });

  $self->rototron->_duty_cache->%* = (); # should build this into Rototron
  # TODO: do something with result

  return;
}

sub handle_duty ($self, $event) {
  $event->mark_handled;

  my (undef, $when) = split /\s+/, $event->text, 2;

  my $when_dt;
  if ($when) {
    $when_dt = eval { parse_date_for_user($when, $event->from_user) };
    return $event->reply_error("I didn't understand the day you asked about")
      unless $when_dt;
  } else {
    $when_dt = DateTime->now(time_zone => $event->from_user->time_zone);
  }

  my $duties = $self->rototron->duties_on($when_dt);

  unless ($duties) {
    return $event->reply("I couldn't get the duty roster!  Sorry.");
  }

  unless (@$duties) {
    $event->reply("Like booze in an airport, today is duty free.");
    return;
  }

  my $reply = "Duty roster for " . $when_dt->ymd . ":\n"
            . join qq{\n}, sort map {; $_->{title} } @$duties;

  $event->reply($reply);
}

1;
