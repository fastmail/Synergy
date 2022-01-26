use v5.28.0;
use warnings;
package Synergy::Role::HasPreferences;

use MooseX::Role::Parameterized;

use Scalar::Util qw(blessed);
use Synergy::Logger '$Logger';
use Try::Tiny;
use utf8;

use experimental qw(signatures);
use namespace::clean;

parameter namespace => (
  isa => 'Str',
);

role {
  my $p = shift;

  requires 'state';
  requires 'save_state';
  requires 'fetch_state';
  requires 'register_with_hub';

  has preference_namespace => (
    is => 'ro',
    isa => 'Str',
    lazy => 1,
    default => sub { $p->namespace // $_[0]->name },
  );

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

  method describe_user_preference => sub ($self, $user, $pref_name) {
    my $val;

    my $ok = try { $val = $self->get_user_preference($user, $pref_name); 1 };

    unless ($ok) {
      $Logger->log("couldn't get value for preference $pref_name: $@");
    }

    return $pref_specs{$pref_name}->{describer}->( $val );
  };

  method preference_help => sub ($self) {
    my %return;
    for my $name (keys %pref_specs) {
      $return{$name} = { $pref_specs{$name}->%{ qw(help description) } };
    }

    return \%return;
  };

  # spec is (for now) {
  #   name        => 'pref_name',
  #   help        => "This is a cool thing.\nIt's very great.",
  #   description => "a pref with a name",
  #   default     => value,
  #   validator   => sub ($self, $val, $event) {},
  #   describer   => sub ($val) {},
  #   after_set   => sub ($self, $username, $value) {},
  # }
  #
  # The validator sub will receive the raw text value from the user, and is
  # expected to return an actual value. If the validator returns undef, we'll
  # give a reasonable error message.
  method add_preference => sub ($class, %spec) {
    confess("Missing required pref. attribute 'name'") unless $spec{name};
    confess("Missing required pref. attribute 'validator'") unless $spec{validator};

    my $name = delete $spec{name};

    die "preference $name already exists in $class" if $pref_specs{$name};

    $spec{describer} //= sub ($value) { return $value // '<undef>' };
    $spec{after_set} //= sub ($self, $username, $value) {};

    $pref_specs{$name} = \%spec;
  };


  method set_preference => sub ($self, $user, $pref_name, $value, $event) {
    unless ($self->is_known_preference($pref_name)) {
      my $full_name = $self->preference_namespace . q{.} . $pref_name;
      $event->error_reply("I don't know about the $full_name preference");
      $event->mark_handled;
      return;
    }

    my $spec = $pref_specs{ $pref_name };
    my ($actual_value, $err) = $spec->{validator}->($self, $value, $event);

    my $full_name = $self->preference_namespace . q{.} . $pref_name;

    if ($err) {
      $event->error_reply("I don't understand the value you gave for $full_name: $err");
      $event->mark_handled;
      return;
    }

    my $got = $self->set_user_preference($user, $pref_name, $actual_value);
    my $desc = $self->describe_user_preference($user, $pref_name);

    my $possessive = $user == $event->from_user
                   ? 'Your'
                   : $user->username . q{'s};

    $event->mark_handled;
    $event->reply("$possessive $full_name setting is now $desc.");
  };

  method user_has_preference => sub ($self, $user, $pref_name) {
    my $username = blessed $user ? $user->username : $user;

    return unless $username; # non-user

    my $user_prefs = $all_user_prefs{$username};
    return exists $user_prefs->{$pref_name} && defined $user_prefs->{$pref_name};
  };

  method get_user_preference => sub ($self, $user, $pref_name) {
    die "unknown pref: $pref_name"
      unless $self->is_known_preference($pref_name);

    my $spec = $pref_specs{ $pref_name };
    my $default = $spec->{default};
    $default = $default->() if $default && ref $default eq 'CODE';

    my $username = blessed $user ? $user->username : $user;
    return unless $username;

    my $user_prefs = $all_user_prefs{$username};

    return $default unless $user_prefs && exists $user_prefs->{$pref_name};
    return $user_prefs->{$pref_name} // $default;
  };

  method set_user_preference => sub ($self, $user, $pref_name, $value) {
    die "unknown pref: $pref_name"
      unless $self->is_known_preference($pref_name);

    my $username = blessed $user ? $user->username : $user;
    my $spec = $pref_specs{ $pref_name };

    $all_user_prefs{$username} //= {};

    my $uprefs = $all_user_prefs{$username};

    # This is necessary if the default value is an empty arrayref or something.
    my $default = $spec->{default};
    if ($default && ref $default eq 'CODE') {
      $default = $default->();
    }

    $uprefs->{$pref_name} = $value // $default;
    delete $uprefs->{$pref_name} unless defined $uprefs->{$pref_name};

    $spec->{after_set}->($self, $username, $uprefs->{$pref_name});

    $self->save_state;

    return $value;
  };

  around state => sub ($orig, $self, @rest) {
    my $state = $self->$orig(@rest);
    $state->{preferences} = $self->user_preferences;
    return $state;
  };

  around register_with_hub => sub ($orig, $self, @rest) {
    $self->$orig(@rest);

    # make sure we've fetched state (and thus, loaded preferences)
    $self->fetch_state;
  };

  around fetch_state => sub ($orig, $self, @rest) {
    my $state = $self->$orig(@rest);

    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }

    return $state;
  };
};

1;
