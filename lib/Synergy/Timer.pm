use v5.16.0;
package Synergy::Timer;
use Moose;
use namespace::autoclean;

use DateTime;

has chill_until_active => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

has chilltill => (
  is  => 'rw',
  isa => 'Int',
  predicate => 'has_chilltill',
  clearer   => 'clear_chilltill',
);

sub chilling {
  my ($self) = @_;
  return 1 if $self->chill_until_active;
  return unless $self->has_chilltill;
  return time <= $self->chilltill;
}

sub is_showtime {
  my ($self) = @_;
  return if $self->chilling;
  return 1 if $self->showtime_is_set_manually;
  $self->clear_showtime, return 1 if $self->is_business_hours;
  return;
}

sub as_hash {
  my ($self) = @_;

  return {} unless $self->chilling;

  if ($self->chill_until_active) {
    return { chill => { type => 'until_active' } };
  }

  return { chill => { type => 'until_time', until => $self->chilltill } };
}

has showtime => (
  isa => 'Bool',
  traits  => [ 'Bool' ],
  handles => { start_showtime => 'set' },
  reader  => 'showtime_is_set_manually',
  clearer => 'clear_showtime',
);

has time_zone => (
  is  => 'rw',
  isa => 'Str',
  required => 1,
);

has business_hours => (
  is => 'ro',
  isa => 'HashRef',
  required => 1,
);

sub is_business_hours {
  my ($self) = @_;

  my $now = DateTime->now(time_zone => $self->time_zone);

  my $dow  = $now->day_of_week;
  my $hour = $now->hour;
  my $min  = $now->minute;

  # Weekends off.
  return if $dow == 7 or $dow == 6;

  # Start nagging
  my ($start_h, $start_m) = split /:/, $self->business_hours->{start}, 2;

  return if $hour <  $start_h,
         or $hour == $start_h && $min < $start_m;

  # Stop nagging
  my ($end_h, $end_m) = split /:/, $self->business_hours->{end}, 2;

  return if $hour >  $end_h
         or $hour == $end_h && $min > $end_m;

  return 1;
}

has last_nag => (
  is  => 'rw',
  predicate => 'has_last_nag',
  clearer   => 'clear_last_nag',
);

has last_saw_timer => (
  is => 'rw',
);

sub last_relevant_nag {
  my ($self) = @_;

  # If we had nagged, but haven't nagged in 45 minutes, let's start over.
  # This could happen, for example, if we were nagging at the end of the
  # business day and now it's morning, or if we were at high-severity nagging
  # before getting told to chill. -- rjbs, 2014-01-15
  my $last_nag = $self->last_nag;
  if ($last_nag and time - $last_nag->{time} > 2700) {
    warn("It's been >45min since last nag.  Resetting nag state.");
    # $self->info("It's been >45min since last nag.  Resetting nag state.");
    $self->clear_last_nag;
    return undef;
  }

  return $last_nag;
}

1;
