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

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
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
  $self->http_get_raw($uri, @arg, Authorization => $self->auth_token);
}

sub http_post ($self, $path, @arg) {
  my $uri = $self->_lp_base_uri . $path;
  $self->http_post_raw($uri, @arg, Authorization => $self->auth_token);
}

sub get_item ($self, $item_id) {
  my $item_res = $self->http_get(
    "/treeitems/?filter[]=id=$item_id",
  );

  return unless $item_res->is_success;

  my $item = $JSON->decode($item_res->decoded_content)->[0];

  return $item;
}

# get timers for user
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

1;
