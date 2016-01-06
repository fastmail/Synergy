use v5.16.0;
package Synergy::User;
use Moose;
use namespace::autoclean;

use Synergy::Timer;

has [ qw(username realname) ] => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has circonus_id => (is => 'ro', isa => 'Int', predicate => 'has_circonus_id');
has phone       => (is => 'ro', isa => 'Int', predicate => 'has_phone');

has nicknames => (
  isa     => 'ArrayRef[Str]',
  traits  => [ 'Array' ],
  handles => { nicknames => 'elements' },
  default => sub {  []  },
);

has timer => (
  is   => 'ro',
  lazy => 1,
  init_arg => undef,
  default  => sub {
    return unless $_[0]->username eq 'rjbs';
    return Synergy::Timer->new;
  },
);

has lp_id    => (is => 'ro', isa => 'Int', predicate => 'has_lp_id');
has lp_token => (is => 'ro', isa => 'Str', predicate => 'has_lp_token');

has lp_ua => (
  is => 'ro',
  lazy    => 1,
  default => sub {
    my ($self) = @_;
    return unless $self->has_lp_token;

    my $ua = LWP::UserAgent::POE->new(keep_alive => 1);

    $ua->default_header('Authorization' => $self->lp_token);

    return $ua;
  },
);

1;
