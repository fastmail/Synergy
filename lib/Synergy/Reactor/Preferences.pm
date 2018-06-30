use v5.24.0;
package Synergy::Reactor::Preferences;

use Moose;
use Try::Tiny;

with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return (
    {
      name      => 'set',
      method    => 'handle_set',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ /\Aset\s+my/i;
      },
    },
    {
      name      => 'dump',
      method    => 'handle_dump',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return 1 if $e->text =~ /\Adump\s+my\s+pref(erence)?s/in;
        return 1 if $e->text =~ /\Adump\s+pref(erence)?s\s+for/in;
        return;
      },
    }
  );
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

sub handle_dump ($self, $event) {
  my ($who) = $event->text =~ /\Adump\s+pref(?:erence)?s\s+for\s+(\w+)/i;
  $who //= 'me';

  my $for_user = $self->resolve_name($who, $event->from_user);

  my @pref_strings;

  for my $component ($self->hub->channels, $self->hub->reactors) {
    next unless $component->does('Synergy::Role::HasPreferences');

    push @pref_strings, $component->describe_user_preference($for_user, $_)
      for $component->preference_names;
  }

  my $prefs = join "\n", @pref_strings;
  my $name = $for_user->username;

  $event->reply("Preferences for $name: ```$prefs```");
  $event->mark_handled;
}

sub _error_no_prefs ($self, $event, $component) {
  $event->mark_handled;
  $event->reply("<$component> does not appear to have preferences");
}

1;
