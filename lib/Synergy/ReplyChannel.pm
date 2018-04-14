use v5.24.0;

package Synergy::ReplyChannel;

use Moose;
use namespace::autoclean;
use Synergy::Logger '$Logger';

use experimental qw(signatures);

my $i = 0;

has [ qw(default_address private_address) ] => (
  is  => 'ro',
  isa => 'Defined',
  weak_ref => 1,
  required => 1,
);

has channel => (
  is    => 'ro',
  does  => 'Synergy::Role::Channel',
  required => 1,
);

has prefix => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

sub reply ($self, $text, $arg) {
  $Logger->log_debug("sending $text to someone");

  # XXX what even to do here
  return $self->channel->send_rich_text($self->default->address, $text, $arg)
    if $self->channel->can('send_rich_text');

  return $self->channel->send_text($self->default_address, $self->prefix . $text);
}

sub rich_reply ($self, $fallback, $text) {
  return $self->reply($fallback) unless $self->channel->can('send_rich_text');
  return $self->channel->send_rich_text($self->default_address, $self->prefix . $text);
}

sub private_reply ($self, $text) {
  $Logger->log_debug("sending $text to someone");
  return $self->channel->send_text($self->private_address, $text);
}

1;
