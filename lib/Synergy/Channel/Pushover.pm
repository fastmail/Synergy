use v5.24.0;
package Synergy::Channel::Pushover;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS qw(encode_json decode_json);

use Synergy::Logger '$Logger';

use Synergy::Event;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has [ qw( token ) ] => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub start ($self) {
}

sub http_post {
  my $self = shift;
  return $self->hub->http_request('POST' => @_);
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  unless ($user->identities->{ $self->name }) {
    $Logger->log([
      "can't send message, no api key for %s",
      $user->username,
    ]);
    return;
  }

  my $where = $user->identities->{ $self->name };
  my $who = $user->username;

  $Logger->log([ "sending pushover <$text> to $who" ]);
  $self->send_message($where, $text, $alts);
}

sub send_message ($self, $target, $text, $alts) {
  my $from;

  my $res = $self->http_post(
    "https://api.pushover.net/1/messages.json",
    Content => [
      token   => $self->token,
      user    => $target,
      message => $text,
    ],
  );

  unless ($res->is_success) {
    $Logger->log("failed to send pushover to $target: " . $res->as_string);
  }

  return $res;
}

sub describe_event ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $event->from_address;
  return "a pushover from $who";
}

1;
