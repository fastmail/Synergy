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
use List::Util qw(uniq);
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
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^(?:(\S+)\s+is\s+)?(un)?available\b/in },
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

  my $target = $event->from_user;
  if ($event->text =~ /^(\S+)\s+is\s+/) {
    $target = $self->resolve_name($1, $event->from_user);
    unless ($target) {
      return $event->error_reply("Sorry, I don't know who you mean.");
    }
  }

  my $text = $event->text;
  my $adj  = $text =~ /unavailable/ ? 'unavailable' : 'available';

  if ($text =~ m{\bon\s+($ymd_re)\z}) {
    $from = parse_date_for_user("$1", $event->from_user);
    $to   = $from->clone;
  } elsif ($text =~ m{\bfrom\s+($ymd_re)\s+to\s+($ymd_re)\z}) {
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
    my $username = $target->username;
    $self->availability_checker->$method(
      $target->username,
      $date,
    );
  }

  $event->reply(
    sprintf "I marked %s %s on %s %s.",
      ($target->username eq $event->from_user->username
        ? 'you'
        : $target->them),
      $adj,
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

# Obviously this is a bit overly specific to my work install.
# -- rjbs, 2019-03-26
#
# We should cache this, but I'd rather be a little slow and correct, for now.
# -- rjbs, 2019-03-26
sub current_triage_officers ($self) {
  my $rototron = $self->rototron;

  my @tzs = sort {; $a cmp $b }
            uniq
            grep {; defined }
            map  {; $_->time_zone }
            $self->hub->user_directory->users;

  my @users;

  for my $tz (@tzs) {
    my $keyword = $tz =~ m{^America/New_York} ? 'triage_us'
                : $tz =~ m{^Australia/}       ? 'triage_au'
                : undef;

    next unless $keyword;


    push @users, grep {; defined && $_->is_working_now }
                 map  {; $self->_user_from_duty($_) }
                 grep {; $_->{keywords}{"rotor:$keyword"} }
                 $rototron->duties_on( DateTime->now(time_zone => $tz) )->@*;
  }

  return @users;
}

sub _user_from_duty ($self, $duty) {
  # We assume only one participant, obviously. -- rjbs, 2019-03-01
  my ($participant) = values $duty->{participants}->%*;
  my ($username)    = $participant->{email} =~ /\A(.+)\@/ ? $1 : undef;

  return unless $username;

  return $self->hub->user_directory->user_named($username);
}

sub handle_duty ($self, $event) {
  $event->mark_handled;

  my (undef, $when) = split /\s+/, $event->text, 2;

  my $when_dt;
  my $is_now;

  if ($when) {
    $when_dt = eval { parse_date_for_user($when, $event->from_user) };
    return $event->reply_error("I didn't understand the day you asked about")
      unless $when_dt;
  } else {
    $is_now = 1;
    $when_dt = DateTime->now(time_zone => $event->from_user->time_zone);
  }

  my @lines;
  for my $rotor ($self->rototron->rotors) {
    my $dt = $when_dt;
    if ($rotor->time_zone && $is_now) {
      $dt = $dt->clone;
      $dt->set_time_zone($rotor->time_zone);
    }

    for my $duty (@{ $self->rototron->duties_on($dt) || [] }) {
      next unless $duty->{keywords}{ $rotor->keyword };

      my $user = $self->_user_from_duty($duty);
      push @lines, $duty->{title}
                 . ', ' . $dt->ymd
                 . (($is_now && $user && $user->is_working_now)
                    ? q{ *(on the clock)*}
                    : q{});
    }
  }

  unless (@lines) {
    my $str = $is_now ? q{today} : q{that time};
    $event->reply("Like booze in an airport, $str is duty free.");
    return;
  }

  my $reply = "*Duty roster for " . $when_dt->ymd . ":*\n"
            . join qq{\n}, sort @lines;

  $event->reply($reply);
}

1;
