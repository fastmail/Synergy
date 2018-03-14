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

has channel_registry => (
  isa => 'HashRef[Object]',
  init_arg  => undef,
  default   => sub {  {}  },
  traits    => [ 'Hash' ],
  handles   => {
    channel_named   => 'get',
    channels        => 'values',
    _add_channel    => 'set',
    _channel_exists => 'exists',
  },
);

sub register_channel ($self, $channel) {
  my $name = $channel->name;

  confess("channel named $name is already registered")
    if $self->_channel_exists($name);

  $self->_add_channel($name, $channel);
  $channel->register_with_hub($self);
  return;
}

has event_handler => (
  is  => 'ro',
  isa      => 'Object',
  required => 1,
  handles  => [ qw( handle_event ) ],
);

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

  return $loop;
}

1;
