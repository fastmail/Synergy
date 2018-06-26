use v5.24.0;
package Synergy::LPC;;

use Moose;

use experimental qw(signatures lexical_subs);
use namespace::clean;
use JSON 2 ();
use Synergy::Logger '$Logger';
use Synergy::LPC; # LiquidPlanner Client, of course
use DateTime;
use utf8;

my $JSON = JSON->new->utf8;

has workspace_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has auth_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has logger_callback => (
  required => 1,
  traits   => [ 'Code' ],
  required => 1,
  handles  => { 'logger' => 'execute_method' },
);

sub log       { (shift)->logger->log(@_) }
sub log_debug { (shift)->logger->log_debug(@_) }

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
}

# Yes, this means that even though an undef payload is technically possible, we
# turn it into a nil result.  If you really need a non-nil undef, construct one
# by hand.  But you probably don't. -- rjbs, 2018-06-26
my sub _failure { state $fail = LPC::Result::Failure->new; return $fail }
my sub _success ($payload) {
  return (defined $payload) ? LPC::Result::Success->new({ payload => $_[0] })
                            : LPC::Result::Success->new;
}

sub _http_failure ($self, $http_res, $desc = undef) {
  $self->log([
    "error with %s: %s",
    $desc // "HTTP operation",
    $http_res->as_string,
  ]);
  return _failure;
}

my $CONFIG;  # XXX use real config

$CONFIG = {
  liquidplanner => {
    package => {
      inbox     => 6268529,
      urgent    => 11388082,
      recurring => 27659967,
    },
    project => {
      comms    => 39452359,
      cyrus    => 38805977,
      fastmail => 36611517,
      listbox  => 274080,
      plumbing => 39452373,
      pobox    => 274077,
      topicbox => 27495364,
    },
  },
};

has http_get_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  traits => [ 'Code' ],
  required => 1,
  handles  => { 'http_get_raw' => 'execute_method' },
);

has http_post_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  traits => [ 'Code' ],
  required => 1,
  handles  => { 'http_post_raw' => 'execute_method' },
);

sub http_get ($self, $path, @arg) {
  my $uri = $self->_lp_base_uri . $path;

  my $http_res = $self->http_get_raw(
    $uri,
    @arg,
    Authorization => $self->auth_token,
  );

  return $self->_http_failure($http_res) unless $http_res->is_success;

  my $payload = $JSON->decode($http_res->decoded_content);
  return _success($payload);
}

sub http_post ($self, $path, @arg) {
  my $uri = $self->_lp_base_uri . $path;

  my $http_res = $self->http_post_raw(
    $uri,
    @arg,
    Authorization => $self->auth_token,
  );

  return $self->_http_failure($http_res) unless $http_res->is_success;

  my $payload = $JSON->decode($http_res->decoded_content);
  return _success($payload);
}

sub get_item ($self, $item_id) {
  my $lp_res = $self->http_get("/treeitems/?filter[]=id=$item_id");

  return $lp_res unless $lp_res->is_success;
  return $lp_res->_success($lp_res->payload->[0]);
}

sub my_timers ($self) {
  return $self->http_get("/my_timers");
}

sub my_running_timer ($self) {
  # Treat as impossible, for now, >1 running timer. -- rjbs, 2018-06-26
  my $timer_res = $self->my_timers;
  return $timer_res unless $timer_res->is_success;

  my ($timer) = grep {; $_->{running} } $self->my_timers->payload_list;
  return _success($timer);
}

# get shortcuts for tasks, projects
# create lp task
# start timer
# stop timer
# reset timer
# track time on task
# get upcoming tasks for member

# generic treeitem get (for damage report)
# get current iteration data

# ?? create todo items
# ?? list todo items

package LPC::Result::Success {
  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);

  sub is_success { 1 };

  has payload => (is => 'ro', predicate => 'has_payload');

  sub is_nil ($self) { ! $self->has_payload }

  sub payload_list ($self) {
    return () if $self->is_nil;

    my $payload = $self->payload;
    Carp::confess("payload_list with non-arrayref payload")
      unless ref $payload and ref $payload eq 'ARRAY';

    return @$payload;
  }

  __PACKAGE__->meta->make_immutable;
}

package LPC::Result::Failure {
  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);

  sub is_success { 0 };
  sub is_nil     { 0 };

  sub payload       { Carp::confess("tried to interpret failure as success") }
  sub payload_list  { Carp::confess("tried to interpret failure as success") }

  __PACKAGE__->meta->make_immutable;
}

1;
