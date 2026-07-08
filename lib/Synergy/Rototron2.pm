use v5.28.0;
use warnings;
package Synergy::Rototron2;

use Moose;
use experimental qw(lexical_subs signatures);

use JSON::MaybeXS;
use Path::Tiny;

use DateTime ();

# This tiny bit of code and comment brought in from Rototron1.  It's still
# useful to know the week-since-epoch of a date, for a rotating random
# tie-breaker.  The big goal in Rototron2 is just to get to ties a lot less
# often.
#
# Let's talk about the epoch here.  It's the first Monday before this program
# existed.  To compute who handles what in a given week, we compute the week
# number, with this week as week zero.  Everything else is a rotation through
# that.
#
# We may very well change this later. -- rjbs, 2019-01-30
my $EPOCH = 1548633600;
my sub week_of_date ($dt) { int( ($dt->epoch - $EPOCH) / (86400 * 7) ) }

package Synergy::Rototron2::Rotor {
  use Moose;
  use experimental qw(lexical_subs signatures);

  use List::Util qw(any max min);

  use Synergy::Logger '$Logger';

  has ident => (is => 'ro', isa => 'Str', required => 1);
  has name  => (is => 'ro', isa => 'Str', required => 1);

  # a map from { date => username }
  has schedule => (
    reader  => '_schedule',
    default => sub {  {}  },
    traits  => [ 'Hash' ],
  );

  sub person_scheduled_on ($self, $dt) {
    return $self->_schedule->{$dt->ymd};
  }

  sub fatigue_for ($self, $person) {
    my $schedule = $self->_schedule;

    # This variable is here for testing. -- rjbs, 2022-09-17
    my $min  = $Synergy::Rototron2::FATIGUE_BACKSTOP
            // DateTime->now(time_zone => 'UTC')->subtract(days => 90)->ymd;
    my @keys = grep {; $_ gt $min } keys %$schedule;

    return scalar grep {; $schedule->{$_} eq $person } @keys;
  }

  sub include_weekends { 0 }

  # a user has "availability_on($date)" method
  # {
  #   username => $preference,
  #   ...
  # }
  #
  # a person's fatigue is the count of keys in the schedule where the key is a
  # date in the last 90d and the value is the username
  has people_preferences => (
    required  => 1,
    traits    => [ 'Hash' ],
    handles   => { people_preferences => 'elements' },
  );

  sub _schedule_dates ($self, $input_dates, $arg) {
    local $Logger = $Logger->proxy({
      proxy_prefix => "rotor " . $self->ident . ": ",
    });

    $Logger->log([
      "scheduling from %s to %s",
      $input_dates->[0]->ymd,
      $input_dates->[-1]->ymd,
    ]);

    my @dates = @$input_dates;
    unless ($self->include_weekends) {
      @dates = grep {; $_->day_of_week < 6 } @dates;
    }

    my $other_rotors = $arg->{other_rotors};
    my $availability_checker = $arg->{availability_checker};

    my %person_preferences = $self->people_preferences;

    my %has_other_duty;
    for my $date (@dates) {
      for my $rotor ($arg->{other_rotors}->@*) {
        if (my $username = $rotor->person_scheduled_on($date)) {
          $has_other_duty{$username} = 1;
        }
      }
    }

    my %preference_group;
    for my $username (keys %person_preferences) {
      my $level = $person_preferences{$username};

      if ($has_other_duty{$username}) {
        # if any user in the group has duty on any other rotor, locally
        # increase their preference number
        $level++;

        $Logger->log([
          "bumping %s to preference %s, already on a rotation this period",
          $username,
          $level,
        ]);
      }

      $preference_group{$level} //= [];
      push $preference_group{$level}->@*, $username;
    }

    LEVEL: for my $level (sort {; $a <=> $b } keys %preference_group) {
      my @people = $preference_group{$level}->@*;

      $Logger->log([
        "%s, level %s, people: %s",
        $self->ident,
        $level,
        \@people
      ]);

      my %days_available;
      my %daycount_available;
      for my $person (@people) {
        my @days = grep {; $availability_checker->($person, $_) } @dates;

        $days_available{$person}     = \@days;
        $daycount_available{$person} =  @days;
      }

      $Logger->log([ 'availability: %s', \%daycount_available ]);

      my ($most_days) = max values %daycount_available;

      unless ($most_days) {
        $Logger->log([
          'nobody at level %s available, will try next level',
          $level,
        ]);

        next LEVEL;
      }

      my @candidates = sort grep {; $daycount_available{$_} == $most_days }
                       keys %daycount_available;

      $Logger->log([ 'most available candidates: %s', \@candidates ]);

      # if set size > 1
      #   pick users with minimum fatigue

      my %fatigue_for;
      for my $person (@candidates) {
        $fatigue_for{$person} = $self->fatigue_for($person);
      }

      $Logger->log([ 'fatigue levels: %s', \%fatigue_for ]);

      my ($least_fatigue) = min values %fatigue_for;

      @candidates = sort grep {; $fatigue_for{$_} == $least_fatigue }
                    keys %daycount_available;

      $Logger->log([ 'least fatigued candidates: %s', \@candidates ]);

      # Here, we assume that all dates in range have the same week.
      # -- rjbs, 2022-09-17
      my $winner = $candidates[ week_of_date($dates[0]) % @candidates ];

      if ($winner) {
        my @can_work = $days_available{ $winner}->@*;
        $Logger->log([
          'and the winner is: %s who will work %s',
          $winner,
          [ map {; $_->ymd } @can_work ],
        ]);

        $self->_commit_user($winner, \@can_work);

        if (@dates != @can_work) {
          my %scheduled   = map {; $_ => 1 } @can_work;
          my @unscheduled = grep {; ! $scheduled{$_} } @dates;

          $Logger->log([
            "couldn't schedule all days, so will try again on: %s",
            [ map {; $_->ymd } @unscheduled ],
          ]);

          return $self->_schedule_dates([ grep {; ! $scheduled{$_} } @dates ], $arg);
        }

        # We did it!  All dates scheduled.
        return;
      }

      $Logger->log([ "no success at level %s", $level ]);
    }

    $Logger->log("failed to schedule!");

    return;
  }

  sub _commit_user ($self, $person, $dates) {
    my $schedule = $self->_schedule;

    for my $ymd (map {; $_->ymd } @$dates) {
      if (my $already = $schedule->{ $ymd }) {
        my $ident = $self->ident;
        confess "rotor $ident already scheduled on $ymd for $already";
      }

      $self->_schedule->{ $ymd } = $person;
    }

    return;
  }

  sub _uncommit_dates ($self, $dates) {
    my $schedule = $self->_schedule;

    for my $ymd (map {; $_->ymd } @$dates) {
      delete $schedule->{ $ymd };
    }

    return;
  }

  __PACKAGE__->meta->make_immutable;
  no Moose;
}

has rotors => (
  isa => 'ArrayRef',
  required  => 1,
  traits    => [ 'Array' ],
  handles   => { rotors => 'elements' },
);

# TODO Replace this with something like (or exactly) the Rototron1 availability
# checker! -- rjbs, 2022-09-17
has availability_checker => (
  is => 'ro',
  required => 1,
);

sub schedule_range ($self, $start_date, $and_next) {
  my %rotors = map {; $_->ident, $_ } $self->rotors;

  my @dates = (
    $start_date,
    map {; $start_date->clone->add(days => $_) } (1 .. $and_next),
  );

  # This "sort" is bogus, nothing should actually matter based on naming of
  # things, but for now, trying to keep it semi-simple and definitely
  # deterministic. -- rjbs, 2022-09-17
  for my $ident (sort keys %rotors) {
    # This "delete local" is less bogus, but deserves a raised eyebrow.  Each
    # rotor wants to be able to say "Aiden is already doing the dishes, let
    # them skip taking out the trash this week" when possible, so knowing the
    # other rotors is useful.  Probably this should be dumped into some kind of
    # availability helper, but I dunno yet. -- rjbs, 2022-09-17
    my $rotor = delete local $rotors{$ident};
    $rotor->_schedule_dates(\@dates, {
      other_rotors => [ values %rotors ],
      availability_checker => $self->availability_checker,
    });
  }

  return;
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
