use v5.24.0;
use warnings;
package Synergy::Event;
use Moose;

use experimental qw(signatures);
use utf8;

use namespace::autoclean;

use Synergy::Logger '$Logger';

has type => (is => 'ro', isa => 'Str', required => 1);
has text => (is => 'ro', isa => 'Str', required => 1); # clearly per-type

has time => (is => 'ro', default => sub { time });

has from_channel => (
  is => 'ro',
  does => 'Synergy::Role::Channel',
  required => 1,
);

has from_address => (
  is => 'ro',
  isa => 'Defined',
  required => 1,
);

has from_user => (
  is => 'ro',
  isa => 'Synergy::User',
);

# This, together with from_channel and from_address can uniquely
# identify someone and where they contacted us. Get this unique
# identifier from ->source_identifier
has conversation_address => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has transport_data => (
  is => 'ro',
);

has was_targeted => (
  is => 'ro',
  isa => 'Bool',
  default => 1,
);

has is_public => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

sub is_private ($self) { ! $self->is_public }

has was_handled => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
  traits  => ['Bool'],
  handles => {
    mark_handled => 'set',
  },
);

sub event_uri ($self) {
  return undef unless $self->from_channel->can('_uri_from_event');
  return $self->from_channel->_uri_from_event($self);
}

sub description ($self) {
  $self->from_channel->describe_event($self);
}

sub BUILD ($self, @) {
  confess "only 'message' events exist for now"
    unless $self->type eq 'message';
}

sub source_identifier ($self) {
  # A unique identifier for where this message came
  # from. Must include the incoming from_address
  # and outgoing conversation_address because
  # of things like slack where from_address
  # could be a user, but they may have spoken
  # in a pm, a channel, or a group conversation
  my $key = join qq{$;},
    $self->from_channel->name,
    $self->from_address,
    $self->conversation_address;
}

sub error_reply ($self, $text, $alts = {}) {
  my $future = $self->reply($text, $alts);
  $self->from_channel->note_error($self, $future);
}

sub reply ($self, $text, $alts = {}) {
  $Logger->log_debug("sending $text to someone");

  my $prefix = $self->is_public
             ? ($self->from_user->username . q{: })
             : q{};

  return $self->from_channel->send_message(
    $self->conversation_address,
    $prefix . $text,
    $alts,
  );
}

sub private_reply ($self, $text, $alts = {}) {
  $Logger->log_debug("sending $text to someone");

  return $self->from_channel->send_message(
    $self->from_address,
    $text,
    $alts,
  );
}

1;
