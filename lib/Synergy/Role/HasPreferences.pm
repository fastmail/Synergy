use v5.24.0;
package Synergy::Role::HasPreferences;

use MooseX::Role::Parameterized;

use Scalar::Util qw(blessed);

use experimental qw(signatures);
use namespace::clean;

role {
  my %pref_specs;

  # This could be better, but we'll access it through methods to keep the
  # dumbness isolated.
  # {
  #   alice => { pref1 => val1, pref2 => val2, ... },
  #   bob   => { ... },
  # }
  my %all_user_prefs;

  method user_preferences    => sub             { +{ %all_user_prefs }      };
  method _load_preferences   => sub ($, $prefs) { %all_user_prefs = %$prefs };
  method preference_names    => sub             { sort keys %pref_specs     };
  method is_known_preference => sub ($, $name)  { exists $pref_specs{$name} };

  around set_preference => sub ($orig, $self, $event, $name, $value) {
    unless ($self->is_known_preference($name)) {
      my $component_name = $self->name;
      $event->reply("I don't know about the $component_name.<$name> preference");
      $event->mark_handled;
      return;
    }

    $self->$orig($event, $name, $value);
  };

  # spec is (for now) {
  #   name      => 'pref_name',
  #   validator => sub ($val) {},
  # }
  #
  # The validator sub will receive the raw text value from the user, and is
  # expected to return an actual value. If the validator returns undef, we'll
  # give a reasonable error message.
  method add_preference => sub ($class, %spec) {
    confess("Missing required pref. attribute 'name'") unless $spec{name};
    confess("Missing required pref. attribute 'validator'") unless $spec{validator};

    my $name = delete $spec{name};
    $pref_specs{$name} = \%spec;
  };


  method set_preference => sub ($self, $event, $pref_name, $value) {
    my $spec = $pref_specs{ $pref_name };
    my ($actual_value, $err) = $spec->{validator}->($value);

    my $full_name = sprintf("%s.%s", $self->name, $pref_name);

    if ($err) {
      $event->reply("I don't understand the value you gave for $full_name: $err.");
      $event->mark_handled;
      return;
    }

    my $user = $event->from_user;
    my $got = $self->set_user_preference($user, $pref_name, $actual_value);

    $event->reply("Your $full_name setting is now '$got'.");
    $event->mark_handled;
  };

  method get_user_preference => sub ($self, $user, $pref_name) {
    die 'unknown pref' unless $self->is_known_preference($pref_name);

    my $username = blessed $user ? $user->username : $user;
    my $user_prefs = $all_user_prefs{$username};

    die 'no pref for user' unless $user_prefs && $user_prefs->{$pref_name};

    return $user_prefs->{$pref_name};
  };

  method set_user_preference => sub ($self, $user, $pref_name, $value) {
    die 'unknown pref' unless $self->is_known_preference($pref_name);

    my $username = blessed $user ? $user->username : $user;

    $all_user_prefs{$username} //= {};

    my $uprefs = $all_user_prefs{$username};
    $uprefs->{$pref_name} = $value;

    $self->save_state;

    return $value;
  };
};

1;
