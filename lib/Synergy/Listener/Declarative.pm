use v5.24.0;
package Synergy::Listener::Declarative;
use Moose;
use Moose::Exporter;

use experimental qw(postderef signatures);
use Synergy::Listener;

Moose::Exporter->setup_import_methods(
  with_meta => [ 'listener' ],
);

my %COMMANDOS;

sub listener ($meta, $name, %spec) {
  my $class = $meta->name;
  my $commando = $COMMANDOS{$class} //= Synergy::Listener::Declarative->new;

  _ensure_attr_exists($meta, $commando);

  $commando->add_listener($name, \%spec);
}

sub _ensure_attr_exists ($meta, $commando) {
  return if $meta->has_attribute('__commando');

  $meta->add_attribute(
    __commando => (
      reader => '__commando',
      init_arg => undef,
      default => sub { $commando },
    ),
  );

  $meta->add_around_method_modifier(
    'listener_specs' => sub ($orig, $self, @rest) {
      my @listeners = $self->$orig(@rest);

      for my $spec ($commando->listener_specs) {
        push @listeners, Synergy::Listener->new({
          reactor => $self,
          %$spec,
        })
      }

      return @listeners;
    },
  );
}

has listeners => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  default => sub { {} },
  handles => {
    has_listener_named => 'exists',
    listener_named     => 'get',
    set_listener       => 'set',
    listener_specs     => 'values',
  },
);

sub add_listener ($self, $name, $spec) {
  die "listener $name registered more than once"
    if $self->has_listener_named($name);

  # We store specs, not Listener objects (which need a reactor).
  $self->set_listener($name, {
    name => $name,
    method => delete $spec->{handler},
    %$spec,
  });
}

no Moose;
1;
