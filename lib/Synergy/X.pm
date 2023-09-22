use v5.32.0;
use warnings;
package Synergy::X;

use Moose;
with 'Throwable',
     'Role::Identifiable::HasIdent';

use experimental qw(signatures);

use overload
  q{""}     => '_stringify',
  fallback  => 1;

around BUILDARGS => sub ($orig, $class, @rest) {
  if (@rest == 1 && ! ref $rest[0]) {
    return $class->$orig({ ident => $rest[0] });
  }

  return $class->$orig(@rest);
};

sub throw_public ($class, $rest) {
  my %arg;

  %arg = ref $rest ? %$rest : (ident => $rest);

  $arg{is_public} = 1;

  $class->throw(\%arg);
}

sub _stringify { $_[0]->message }

has message => (
  is    => 'ro',
  isa   => 'Str',
  lazy  => 1,
  default => sub { $_[0]->ident },
  predicate => 1,
);

has is_public => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has extra_data => (
  is  => 'ro',
  isa => 'HashRef',
);

1;
