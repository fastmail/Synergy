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

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
}

sub _link_base_uri ($self) {
  return sprintf "https://app.liquidplanner.com/space/%s/projects/panel/",
    $self->workspace_id;
}

sub item_uri ($self, $task_id) {
  return $self->_link_base_uri . $task_id;
}

my $CONFIG;  # XXX use real config

$CONFIG = {
  liquidplanner => {
    workspace => 14822,
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
  handles  => { 'http_get' => 'execute_method' },
);

has http_post_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  traits => [ 'Code' ],
  required => 1,
  handles  => { 'http_post' => 'execute_method' },
);

sub get_item ($self, $item_id) {
  my $item_res = $self->http_get(
    "/treeitems/?filter[]=id=$item_id",
  );

  return unless $item_res->is_success;

  my $item = $JSON->decode($item_res->decoded_content)->[0];

  return $item;
}

# get item/task by id
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
