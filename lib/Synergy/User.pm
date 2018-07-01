use v5.16.0;
package Synergy::User;

use Moose;
# This comment-out should be temporary; just here to deal with unknown config
# from gitlab.  -- michael, 2018-04-13
# use MooseX::StrictConstructor;
use experimental qw(signatures);

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

has default_project_shortcut => (is => 'ro', isa => 'Str');

# We should be able to remove this eventually, but I'm leaving it for now so
# ew can auto-fill these from config if need be.
has lp_token => (is => 'ro', isa => 'Str', predicate => 'has_lp_token');

1;
