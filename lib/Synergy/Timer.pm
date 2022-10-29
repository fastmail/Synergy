use v5.34.0;
use warnings;
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
  is => 'rw',
  isa => 'HashRef',
  required => 1,
);

sub is_business_hours {
  my ($self) = @_;

  my $now = DateTime->now(time_zone => $self->time_zone);

  my $dow  = $now->day_of_week;
  my $hour = $now->hour;
  my $min  = $now->minute;

  state $key = [ undef, qw( mon tue wed thu fri sat sun ) ];
  my $hours = $self->business_hours->{ $key->[ $dow ] };

  # No hours for today?  Not working.
  return unless $hours && %$hours;

  # Start nagging
  my ($start_h, $start_m) = split /:/, $hours->{start}, 2;

  return if $hour <  $start_h,
         or $hour == $start_h && $min < $start_m;

  # Stop nagging
  my ($end_h, $end_m) = split /:/, $hours->{end}, 2;

  return if $hour >  $end_h
         or $hour == $end_h && $min > $end_m;

  return 1;
}

1;
