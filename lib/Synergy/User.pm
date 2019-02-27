use v5.16.0;
use warnings;
package Synergy::User;

use Moose;
# This comment-out should be temporary; just here to deal with unknown config
# from gitlab.  -- michael, 2018-04-13
# use MooseX::StrictConstructor;
use experimental qw(signatures);
use utf8;

use namespace::autoclean;

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

  return $self->directory->hub->format_friendly_date($dt);
}

has expandoes => (
  reader  => '_expandoes',
  isa     => 'HashRef',
  traits  => [ 'Hash' ],
  default => sub {  {}  },
);

sub defined_expandoes ($self) {
  my $expandoes = $self->_expandoes;
  my @keys = grep {; $expandoes->{$_}->@*  } keys %$expandoes;
  return @keys;
}

sub tasks_for_expando ($self, $name) {
  return unless my $expando = $self->_expandoes->{ $name };
  return @$expando;
}

has identities => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

has phone       => (is => 'ro', isa => 'Str', predicate => 'has_phone');
has want_page   => (is => 'ro', isa => 'Bool', default => 1);

has should_nag  => (is => 'ro', isa => 'Bool', default => 0);

has _nicknames => (
  is      => 'ro',
  isa     => 'ArrayRef[Str]',
  default => sub {  []  },
);

sub nicknames ($self) {
  my $nicks = $self->preference('nicknames') // $self->_nicknames;
  return @$nicks;
}

has business_hours => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {
    {
      start => '10:30',
      end   => '17:00',
    }
  },
);

has default_project_shortcut => (is => 'ro', isa => 'Str');

has lp_id    => (is => 'ro', isa => 'Int', predicate => 'has_lp_id');

has deleted => ( is => 'ro', isa => 'Bool' );
sub is_deleted { $_[0]->deleted }

1;
