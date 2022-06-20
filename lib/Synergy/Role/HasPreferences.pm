use v5.28.0;
use warnings;
package Synergy::Role::HasPreferences;

use MooseX::Role::Parameterized;

use Future;
use Scalar::Util qw(blessed);
use Synergy::Exception;
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

  # all synchronous.
  method user_preferences    => sub             { +{ %all_user_prefs }      };
  method _load_preferences   => sub ($, $prefs) { %all_user_prefs = %$prefs };
  method preference_names    => sub             { sort keys %pref_specs     };
  method is_known_preference => sub ($, $name)  { exists $pref_specs{$name} };

  # async: returns a future that resolves to a string
  method describe_user_preference => sub ($self, $user, $pref_name) {
    my $val;

    my $ok = try { $val = $self->get_user_preference($user, $pref_name); 1 };

    unless ($ok) {
      $Logger->log("couldn't get value for preference $pref_name: $@");
    }

    # Really, this should "never fail", but.
    return Future->wrap($pref_specs{$pref_name}->{describer}->($val))
      ->else(sub (@err) {
        my $full_name = $self->preference_namespace . q{.} . $pref_name;
        $Logger->log([ "error describing $full_name: %s", \@err ]);
        return Future->done('<mysterious error describing preference>');
      });
  };

  # sync
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
  #   validator   => sub ($self, $val, $event) {},  <-- ASYNC
  #   describer   => sub ($val) {},                 <-- ASYNC
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

    $spec{describer} //= sub ($val) { return Future->done($val // '<unset>') };
    $spec{after_set} //= sub ($self, $username, $value) {};

    $pref_specs{$name} = \%spec;
  };

  # Returns a future with no useful return value
  method set_preference => sub ($self, $user, $pref_name, $value, $event) {
    my $full_name = $self->preference_namespace . q{.} . $pref_name;

    unless ($self->is_known_preference($pref_name)) {
      $event->error_reply("I don't know about the $full_name preference");
      $event->mark_handled;
      return;
    }

    my $spec = $pref_specs{ $pref_name };

    my ($actual_value, $err) = $spec->{validator}->($self, $value, $event);

    return $spec->{validator}->($self, $value, $event)
      ->then(sub ($actual_value) {
        my $got = $self->set_user_preference($user, $pref_name, $actual_value);
        return $self->describe_user_preference($user, $pref_name);
      })->then(sub ($desc) {
        my $possessive = $user == $event->from_user
                       ? 'Your'
                       : $user->username . q{'s};

        $event->mark_handled;
        $event->reply("$possessive $full_name setting is now $desc.");
      })->else(sub ($err, @hrm) {
        use Data::Dumper::Concise;
        warn Dumper {
          err => $err,
          rest => \@hrm,
        };
        if ($err->isa('Synergy::Exception::PreferenceValidation')) {
          my $msg = $err->message;
          $event->mark_handled;
          return $event->error_reply("I don't understand the value you gave for $full_name: $msg");
        }

        if ($err->isa('Synergy::Exception::PreferenceDescription')) {
          my $msg = $err->message;
          $event->mark_handled;
          return $event->reply(
            "I set the $full_name pref, but something went wrong describing it back: $msg"
          );
        }
      });
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

sub pref_validation_error ($message) {
  return Synergy::Exception->new('PreferenceValidation', $message);
}

1;
