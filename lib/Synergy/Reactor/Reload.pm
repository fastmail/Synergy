use v5.24.0;
package Synergy::Reactor::Reload;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);
use Time::Duration::Parse;
use Time::Duration;

has lp_reactor_name => (
  is => 'ro',
  isa => 'Str',
);

sub listener_specs {
  return {
    name      => 'reload',
    method    => 'handle_reload',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^reload(\s|$)/i },
  };
}

sub handle_reload ($self, $event, $rch) {
  $event->mark_handled;

  my ($what) = $event->text =~ s/^reload\s+//r;

  return $rch->reply("I only know how to reload <projects> right now")
    unless $what eq 'projects';

  return $rch->reply("I don't seem to have a liquid-planner reactor")
    unless $self->lp_reactor_name;

  my $lp = $self->hub->reactor_named($self->lp_reactor_name);

  $lp->_set_projects($lp->get_project_nicknames);
  $rch->reply("Projects reloaded");
}

1;
