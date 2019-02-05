use v5.24.0;
use warnings;
package Synergy::Reactor::Preferences;

use Moose;
use Try::Tiny;
use Synergy::Logger '$Logger';
use utf8;

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
      name      => 'list_all_preferences',
      method    => 'handle_list',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ /\Alist\s+all\s+preferences\s*\z/i;
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
  unless ($for_user) {
    $event->mark_handled;
    return $event->error_reply(qq!I don't know who "$who" is!);
  }

  my @pref_strings;
  my $hub = $self->hub;

  for my $component ($hub->user_directory, $hub->channels, $hub->reactors) {
    next unless $component->has_preferences;

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

sub handle_list ($self, $event) {
  my @sources = map {; [ $_->preference_namespace, $_ ] }
    $self->hub->user_directory,
    grep {; $_->does('Synergy::Role::HasPreferences') } $self->hub->reactors;

  my $text = qq{*Known preferences are:*\n};
  for my $source (sort { $_->[0] cmp $_->[1] } @sources) {
    my ($ns, $has_pref) = @$source;

    my $help = $has_pref->preference_help;
    for my $key (sort keys %$help) {
      $text .= sprintf "%s.%s - %s\n",
        $ns,
        $key,
        $help->{$key}{description} // 'mystery preference';
    }
  }

  $event->mark_handled;

  chomp $text;
  $event->reply($text);
}

1;
