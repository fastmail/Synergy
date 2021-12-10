use v5.24.0;
use warnings;
package Synergy::Event;
use Moose;

use experimental qw(signatures);
use utf8;

use namespace::autoclean;

use Future;
use Synergy::Logger '$Logger';
use Synergy::Util qw(transliterate);

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
    mark_handled   => 'set',
    mark_unhandled => 'unset',
  },
);

around mark_handled => sub ($orig, $self, @rest) {
  $self->$orig(@rest);
  return Future->done;
};

sub event_uri ($self) {
  return undef unless $self->from_channel->can('_uri_from_event');
  return $self->from_channel->_uri_from_event($self);
}

sub description ($self) {
  $self->from_channel->describe_event($self);
}

sub short_description ($self) {
  if ($self->from_channel->can('describe_event_concise')) {
    return $self->from_channel->describe_event_concise($self);
  }

  $self->from_channel->describe_event($self);
}

my %known_types = map {; $_ => 1 } qw(message edit);
sub BUILD ($self, @) {
  confess "unknown event type " . $self->type
    unless $known_types{ $self->type };
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

# Ephemeral replies cannot have alts. -- michael, 2019-02-05
sub ephemeral_reply($self, $text) {
  return $self->reply($text)
    unless $self->from_channel->can('send_ephemeral_message');

  return $self->from_channel->send_ephemeral_message(
    $self->conversation_address,
    $self->from_address,
    "Psst: $text",
  );
}

sub error_reply ($self, $text, $alts = {}) {
  return $self->reply($text, $alts, { was_error => 1 });
}

sub reply_error ($self, $text, $alts = {}) {
  return $self->reply($text, $alts, { was_error => 1 });
}

sub reply ($self, $text, $alts = {}, $args = {}) {
  $Logger->log_debug("sending $text to someone");

  my $prefix = $self->from_user && $self->is_public
             ? ($self->from_user->username . q{: })
             : q{};

  if ($self->from_user && $self->from_user->preference('alphabet')) {
    $text = transliterate($self->from_user->preference('alphabet'), $text);
  }

  $text = $prefix . $text;

  $self->from_channel->run_pre_message_hooks($self, \$text, $alts);

  my $future = $self->from_channel->send_message(
    $self->conversation_address,
    $text,
    $alts,
  );

  $self->from_channel->note_reply($self, $future, $args);
  return $future;
}

sub private_reply ($self, $text, $alts = {}) {
  $Logger->log_debug([
    "sending message <<<%s>>> to  %s",
    $text,
    $self->from_address,
  ]);

  return $self->from_channel->send_message(
    $self->from_address,
    $text,
    $alts,
  );
}

1;
