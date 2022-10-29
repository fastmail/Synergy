use v5.34.0;
use warnings;
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
  my $where = $user->identity_for($self->name);
  my $who = $user->username;

  unless ($where) {
    $Logger->log([
      "can't send message, no api key for %s",
      $user->username,
    ]);
    return;
  }

  $Logger->log([ "sending pushover <$text> to $who" ]);
  $self->send_message($where, $text, $alts);
}

sub send_message ($self, $target, $text, $alts = {}) {
  my $from;

  my $res = $self->http_post(
    "https://api.pushover.net/1/messages.json",
    Content => [
      token   => $self->token,
      user    => $target,
      message => $text,
    ],
  )->get;

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

sub describe_conversation ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $event->from_address;
  return $who;
}

1;
