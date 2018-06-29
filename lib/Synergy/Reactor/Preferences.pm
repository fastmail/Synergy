use v5.24.0;
package Synergy::Reactor::Preferences;

use Moose;
use Try::Tiny;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'set',
    method    => 'handle_set',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->was_targeted;
      return unless $e->text =~ /\Aset\s+my/; },
  };
}

sub handle_set ($self, $event) {
  my ($comp_name, $pref_name, $pref_value) =
    $event->text =~ m{\A set \s+ my \s+                 # set my
                      ([-_a-z0-9]+) \.  ([-_a-z0-9]+)   # component.pref
                      \s+ to \s+ (.*)                   # to value
                     }x;

  my $component;
  try {
    $component = $self->hub->component_named($comp_name);
  } catch {
    $self->_error_no_prefs($event, $comp_name)
      if /Could not find channel or reactor/;
  };

  return unless $component;

  return $self->_error_no_prefs($event, $comp_name)
    unless $component->can('set_preference');

  $component->set_preference($event, $pref_name, $pref_value);
}

sub _error_no_prefs ($self, $event, $component) {
  $event->mark_handled;
  $event->reply("<$component> does not appear to have preferences");
}

1;
