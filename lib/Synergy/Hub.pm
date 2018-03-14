use v5.24.0;
package Synergy::Hub;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

has user_directory => (
  is  => 'ro',
  isa => 'Object',
  required  => 1,
);

for my $pair (
  [ qw( channel channels ) ],
  [ qw( reactor reactors ) ],
) {
  my ($s, $p) = @$pair;

  my $exists = "_$s\_exists";
  my $add    = "_add_$s";

  has "$s\_registry" => (
    isa => 'HashRef[Object]',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      "$s\_named" => 'get',
      $p          => 'values',
      $add        => 'set',
      $exists     => 'exists',
    },
  );

  Sub::Install::install_sub({
    as    => "register_$s",
    code  => sub ($self, $thing) {
      my $name = $thing->name;

      confess("$s named $name is already registered") if $self->$exists($name);

      $self->$add($name, $thing);
      $thing->register_with_hub($self);
      return;
    }
  });
}

sub handle_event ($self, $event, $rch) {
  my @hits;
  for my $reactor ($self->reactors) {
    for my $listener ($reactor->listeners) {
      next unless $listener->matches_event($event);
      push @hits, [ $reactor, $listener ];
    }
  }

  # Probably we later want a "huh?" for targeted/private events.
  return unless @hits;

  if (1 < grep {; $_->[1]->is_exclusive } @hits) {
    $rch->reply("Sorry, I find that message ambiguous.");
    return;
  }

  for my $hit (@hits) {
    my $method = $hit->[1]->method;
    $hit->[0]->$method($event, $rch);
  }

  return;
}

has loop => (
  reader => '_get_loop',
  writer => '_set_loop',
  init_arg  => undef,
);

sub loop ($self) {
  my $loop = $self->_get_loop;
  confess "tried to get loop, but no loop registered" unless $loop;
  return $loop;
}

sub set_loop ($self, $loop) {
  confess "tried to set loop, but look already set" if $self->_get_loop;
  $self->_set_loop($loop);

  $_->start for $self->channels;
  $_->start for $self->reactors;

  return $loop;
}

1;
