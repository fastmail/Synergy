use v5.34.0;
use warnings;
package Synergy::User;

use Moose;
# This comment-out should be temporary; just here to deal with unknown config
# from gitlab.  -- michael, 2018-04-13
# use MooseX::StrictConstructor;
use experimental qw(signatures);
use utf8;

use DateTime;
use namespace::autoclean;

use Synergy::Logger '$Logger';
use Synergy::Timer;

has directory => (
  is => 'ro',
  weak_ref => 1,
  required => 1,
);

sub preference ($self, $pref_name) {
  $self->directory->get_user_preference($self, $pref_name);
}

has is_master => (is => 'ro', isa => 'Bool');

has is_virtual => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has username => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has _realname => (
  is    => 'ro',
  isa   => 'Str',
  lazy  => 1,
  default => sub { $_[0]->username },
  predicate => 'has_realname',
  init_arg  => 'realname',
);

sub realname ($self) {
  return $self->preference('realname') // $self->_realname;
}

my %PRONOUN = (
  he    => [ qw( he   him  his   his     himself  ) ],
  she   => [ qw( she  her  her   hers    herself  ) ],
  they  => [ qw( they them their theirs  themself ) ],
);

sub _pronoun {
  my $which = $_[0]->preference('pronoun') // 'they';
  return $PRONOUN{ $which } // $PRONOUN{they};
}

sub they      { $_[0]->_pronoun->[0] }
sub them      { $_[0]->_pronoun->[1] }
sub their     { $_[0]->_pronoun->[2] }
sub theirs    { $_[0]->_pronoun->[3] }
sub theyre    { my $p = $_[0]->_pronoun->[0]; $p eq 'they' ? "they're" : "$p\'s" }
sub themself  { $_[0]->_pronoun->[4] }

has wtf_replies => (
  isa => 'ArrayRef',
  traits  => [ qw(Array) ],
  handles => { wtf_replies => 'elements' },
  default => sub {  []  },
);

has _time_zone => (
  is => 'ro',
  init_arg => 'time_zone',
  lazy => 1,
  default => 'America/New_York',
);

sub time_zone ($self) {
  return $self->preference('time-zone') // $self->_time_zone;
}

sub format_timestamp ($self, $ts, $format = undef) {
  my $dt = DateTime->from_epoch(epoch => $ts);
  return $self->format_datetime($ts, $format);
}

sub format_datetime ($self, $dt, $format = undef) {
  if (! blessed $dt) {
    $dt = DateTime->from_epoch(epoch => $dt);
  }

  $dt = $dt->clone;
  $dt->set_time_zone($self->time_zone);

  if ($format) {
    return $dt->strftime($format);
  }

  return $self->directory->env->format_friendly_date($dt);
}

has identities => (
  is => 'ro',
  isa => 'HashRef',
  traits => [ 'Hash' ],
  default => sub {  {}  },
  handles => {
    add_identity        => 'set',
    identity_for        => 'get',
    has_identity_for    => 'exists',
    delete_identity_for => 'delete',
    identity_pairs      => 'kv',
  },
);

sub phone ($self)     { return $self->preference('phone') }
sub has_phone ($self) { return !! $self->phone }

has should_nag  => (is => 'ro', isa => 'Bool', default => 0);

has _nicknames => (
  is      => 'ro',
  isa     => 'ArrayRef[Str]',
  default => sub {  []  },
  predicate => 'has_nicknames',
  init_arg  => 'nicknames',
);

sub nicknames ($self) {
  my $nicks = $self->preference('nicknames') // $self->_nicknames;
  return @$nicks;
}

sub business_hours ($self) {
  my $hours = $self->preference('business-hours');
  $hours //= {
    sun => undef,
    mon => { start => '09:30', end => '17:00' },
    tue => { start => '09:30', end => '17:00' },
    wed => { start => '09:30', end => '17:00' },
    thu => { start => '09:30', end => '17:00' },
    fri => { start => '09:30', end => '17:00' },
    sat => undef,
  };

  return $hours;
}

sub is_working_now ($self) {
  my $timer = Synergy::Timer->new({
    time_zone      => $self->time_zone,
    business_hours => $self->business_hours,
  });

  return $timer->is_business_hours;
}

state $DOW_NAME = [ undef, qw( mon tue wed thu fri sat sun ) ];

sub hours_for_dow ($self, $dow) {
  my $hours = $self->business_hours->{ $DOW_NAME->[ $dow ] };

  return undef unless $hours && %$hours;
  return $hours;
}

sub is_wfh_on ($self, $dow) {
  my $wfh_days = $self->preference('wfh-days');
  return !! grep {; $_ eq $dow } @$wfh_days;
}

# We must now inject $hub, because the directory is not necessarily attached
# to one.
sub shift_for_day ($self, $hub, $moment) {
  my $when  = DateTime->from_epoch(
    time_zone => $self->time_zone,
    epoch     => $moment->epoch,
  );

  return unless my $hours = $self->hours_for_dow($when->day_of_week);

  if (my $roto = $hub->reactor_named('rototron')) {
    return unless $roto->rototron->user_is_available_on($self->username, $when);
  }

  my %shift;
  for my $key (qw( start end )) {
    my ($h, $m) = split /:/, $hours->{$key}, 2;

    $shift{$key} = DateTime->new(
      year      => $when->year,
      month     => $when->month,
      day       => $when->day,
      hour      => $h,
      minute    => $m,
      time_zone => $self->time_zone,
    )->epoch;
  }

  return \%shift;
}

sub is_on_duty ($self, $hub, $duty_name) {
  return unless my $roto = $hub->reactor_named('rototron');

  my $username = $self->username;

  if ($duty_name eq 'triage') {
    # Special-cased because it duplexes triage_au & triage_us.
    return grep { $_->username eq $username } $roto->current_triage_officers;
  }

  return grep { $_->username eq $username }
         $roto->current_officers_for_duty($duty_name);
}

has deleted => ( is => 'ro', isa => 'Bool' );
sub is_deleted { $_[0]->deleted }

1;
