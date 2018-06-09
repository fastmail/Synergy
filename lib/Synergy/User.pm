use v5.16.0;
package Synergy::User;

use Moose;
# This comment-out should be temporary; just here to deal with unknown config
# from gitlab.  -- michael, 2018-04-13
# use MooseX::StrictConstructor;
use experimental qw(signatures);

use namespace::autoclean;

use Synergy::Timer;

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

has realname => (
  is    => 'ro',
  isa   => 'Str',
  lazy  => 1,
  default => sub { $_[0]->username },
);

has wtf_replies => (
  isa => 'ArrayRef',
  traits  => [ qw(Array) ],
  handles => { wtf_replies => 'elements' },
  default => sub {  []  },
);

has time_zone => (
  is => 'ro',
  default => 'America/New_York',
);

sub format_datetime ($self, $dt, $format = '%F %R %Z') {
  $dt = $dt->clone;
  $dt->set_time_zone($self->time_zone);
  return $dt->strftime($format);
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

has nicknames => (
  isa     => 'ArrayRef[Str]',
  traits  => [ 'Array' ],
  handles => { nicknames => 'elements' },
  default => sub {  []  },
);

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

has lp_id    => (is => 'ro', isa => 'Int', predicate => 'has_lp_id');
has lp_token => (is => 'ro', isa => 'Str', predicate => 'has_lp_token');

sub lp_auth_header {
  my $self = shift;

  return unless $self->has_lp_token;

  if ($self->lp_token =~ /-/) {
    return "Bearer " . $self->lp_token;
  } else {
    return $self->lp_token;
  }
}

1;
