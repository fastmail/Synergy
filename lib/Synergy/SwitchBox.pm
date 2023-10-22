use v5.32.0;
use warnings;

package Synergy::SwitchBox;
use Moose;

use experimental qw(signatures);

# name    - str
# aliases - str[]
# type    - str, int, num, bool, enum
# join    - 0/1
# multi   - 0/1
# default?

# my $switcher = Switcher->new({
#   version => { type => 'Str' },
#   tag     => { type => 'Str' }
# });
has schema => (
  is => 'ro',
  required => 1,
);

has switchset_class => (
  is => 'ro',
  lazy => 1,
  builder => '_build_switchset_class',
);

# create a class with methods for the properties
sub _build_switchset_class ($self) {
  state $counter = 0;

  # It'd be nice if we could include the name of the package where this object
  # was being constructed, but I'm not sure it's quite trivial to get that.
  # (Look at StackTrace::Auto and weep.) -- rjbs, 2023-10-21
  my $package = join q{::}, __PACKAGE__, "_SwitchSet", ++$counter;

  my $meta = Moose::Meta::Class->initialize($package);
  $meta->superclasses('Synergy::SwitchBox::Set');

  my $schema = $self->schema;
  ATTR: for my $name (sort keys %$schema) {
    if ($schema->{$name}{multi}) {
      $meta->add_attribute($name,
        isa   => 'ArrayRef[Value]',
        traits  => [ 'Array' ],
        handles => { $name => 'elements' },
        default => sub {  []  },
      );
      next ATTR;
    }

    $meta->add_attribute($name,
      is    => 'ro',
      isa   => 'Value',
    );
  }

  return $meta->name;
}

# get check with Moose::Util::TypeConstraints::find_type_constraint
# call: my $error = $TC->validate( $value )
# or  : my $is_ok = $TC->check( $value )
sub _check_and_coerce_values ($self, $schema, $values) {
  state %Type = (
    str => Moose::Util::TypeConstraints::find_type_constraint('Str'),
    num => Moose::Util::TypeConstraints::find_type_constraint('Num'),
    int => Moose::Util::TypeConstraints::find_type_constraint('Int'),
    bool => 1, # special
  );

  my $type_name = $schema->{type};
  return unless $type_name;

  confess("unknown type $type_name") unless exists $Type{$type_name};

  my @invalid;

  if ($type_name eq 'bool') {
    state %Truthy = map {; $_ => 1 } qw( on  true  yes   1 );
    state %Falsy  = map {; $_ => 1 } qw( off false noyes 0 );

    my @new_values;
    VALUE: for my $value (@$values) {
      if ($Truthy{$value}) { push @new_values, 1; next VALUE }
      if ($Falsy{$value})  { push @new_values, 0; next VALUE }

      push @invalid, $value;
    }

    @$values = @new_values unless @invalid;
  } else {
    @invalid = grep {; ! $Type{$type_name}->check($_) } @$values;
  }

  return unless @invalid;

  # We have @invalid so we could include it here, but we'd want some way to
  # merge failures at the end.  Rather than think about it now, punt...
  # -- rjbs, 2023-10-22
  return { wanted => $type_name }
}

sub handle_switches ($self, $switches) {
  my %switch;

  my %error;
  # return SwitchBox::Set if good
  # throw Switchbox::Error if bad
  SWITCH: for my $switch (@$switches) {
    unless ($switch && @$switch) {
      $error{empty_switch} = 1; # Woah.
      next SWITCH;
    }

    my ($name, @args) = @$switch;

    unless (defined $name) {
      $error{undef_name} = 1; # Yow.
      next SWITCH;
    }

    unless (exists $self->{schema}{$name}) {
      $error{unknown}{$name} = 1;
      next SWITCH;
    }

    my $schema = $self->{schema}{$name};

    if ($schema->{join} && @args > 1) {
      @args = join q{ }, @args;
    }

    if (@args == 0) {
      if ($schema->{type} eq 'bool') {
        @args = 1;
      } else {
        $error{switch}{$name}{novalue} = 1;
        next SWITCH;
      }
    }

    # This may alter @args in place! -- rjbs, 2023-10-22
    my $value_error = $self->_check_and_coerce_values($schema, \@args);

    if ($value_error) {
      $error{switch}{$name}{value} = $value_error;
      next SWITCH;
    }

    if ($schema->{multi}) {
      $switch{$name} //= [];
      push $switch{$name}->@*, @args;
      next SWITCH;
    }

    if (
      (@args > 1)
      ||
      (exists $switch{$name})
    ) {
      $error{switch}{$name}{multi} = 1;
      next SWITCH;
    }

    $switch{$name} = $args[0];
  }

  if (%error) {
    Synergy::SwitchBox::Error->throw({ errors => \%error });
  }

  return $self->switchset_class->new(\%switch);
}

package Synergy::SwitchBox::Error {
  use Moose;
  with 'Throwable';

  has _errors => (
    is => 'ro',
    isa => 'HashRef',
    required => 1,
    init_arg => 'errors',
  );

  sub as_structs ($self) {
    my @structs;
    my %errors = $self->_errors->%*;

    for my $switch (keys $errors{switch}->%*) {
      for my $type (keys $errors{switch}{$switch}->%*) {
        push @structs, { switch => $switch, type => $type };
      }
    }

    for my $switch (keys $errors{unknown}->%*) {
      push @structs, { switch => $switch, type => 'unknown' };
    }

    # These are super weird but let's not just drop them on the floor.
    push @structs, { type => 'undef-name' }   if $errors{undef_name};
    push @structs, { type => 'empty-switch' } if $errors{empty_switch};

    return @structs;
  }

  no Moose;
}

package Synergy::SwitchBox::Set {
  use Moose;

  no Moose;
}

1;
