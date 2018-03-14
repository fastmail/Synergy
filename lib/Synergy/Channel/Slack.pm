use v5.24.0;
package Synergy::Channel::Slack;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS qw(encode_json decode_json);

use Synergy::Event;
use Synergy::ReplyChannel;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has slack => (
  is => 'ro',
  isa => 'Synergy::External::Slack',
  lazy => 1,
  default => sub ($self) {
    Synergy::External::Slack->new(
      loop    => $self->loop,
      api_key => $self->api_key,
    );
  }
);

sub start ($self) {
  $self->slack->connect;

  $self->slack->client->{on_frame} = sub ($client, $frame) {
    return unless $frame;

    my $event;
    unless (eval { $event = decode_json($frame) }) {
      warn "ERROR DECODING <$frame> <$@>\n";
      return;
    }

    if ($event->{type} eq 'hello') {
      $self->slack->setup if $event->{type} eq 'hello';
      return;
    }

    # XXX dispatch these better
    return unless $event->{type} eq 'message';

    # This should go in the event handler, probably
    return if $event->{bot_id};
    return if $self->slack->username($event->{user}) eq 'synergy';

    my $from_user = $self->hub->user_directory->resolve_user($self->name, $event->{user});

    my $evt = Synergy::Event->new({
      type => 'message',
      text => $self->decode_slack_usernames($event->{text}),
      from_channel => $self,
      from_address => $self->slack->users->{$event->{user}}->{name},
      ( $from_user ? ( from_user => $from_user ) : () ),
    });

    my $rch = Synergy::ReplyChannel->new(
      channel => $self,
      default_address => $event->{channel},
      private_address => $event->{user},
    );

    $self->hub->handle_event($evt, $rch);
  };
}

# TODO: re-encode these on reply?
sub decode_slack_usernames ($self, $text) {
  return $text =~ s/<\@(U[A-Z0-9]+)>/"@" . $self->slack->username($1)/ger;
}

sub send_text ($self, $target, $text) {
  $self->slack->api_call("chat.postMessage", {
    text    => $text,
    channel => $target,
    as_user => 1,
  });
  return;
}

1;
