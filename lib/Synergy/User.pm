use v5.16.0;
package Synergy::User;

use Moose;
use MooseX::StrictConstructor;
use experimental qw(signatures);

use namespace::autoclean;

use Synergy::Timer;

has is_master => (is => 'ro', isa => 'Bool');

has [ qw(username realname) ] => (
  is => 'ro',
  isa => 'Str',
  required => 1,
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

has timer => (
  is   => 'ro',
  lazy => 1,
  init_arg => undef,
  default  => sub {
    return unless $_[0]->has_lp_token;
    return Synergy::Timer->new({
      time_zone      => $_[0]->time_zone,
      business_hours => $_[0]->business_hours,
    });
  },
);

has last_lp_timer_id => (
  is => 'rw',
  isa => 'Str',
  clearer => 'clear_last_lp_timer_id',
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
