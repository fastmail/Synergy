use v5.24.0;
package Synergy::Channel::Twilio;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS qw(encode_json decode_json);

use Synergy::Event;
use Synergy::ReplyChannel;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has [ qw( sid auth from ) ] => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has numbers => (
  is => 'ro',
  isa => 'HashRef',
  required => 1,
);

sub start ($self) {
  $self->hub->server->register_path('/sms', sub ($req) {
    return [200, [], [ 'great!' ]];
  });
}

sub http_post {
  my $self = shift;
  return $self->hub->http_request('POST' => @_);
}

sub send_message_to_user ($self, $user, $text) {
  unless ($user->phone) {
    warn "No user phone number for " . $user->username . "\n";
    return;
  }

  my $where = $user->phone;

  $self->send_text($where, $text);
}


sub send_text ($self, $target, $text) {
  my $from;

  unless ($from) {
    $from = $self->from;
    COUNTRY: for my $code (
      sort { length $b <=> length $a } keys $self->numbers->%*
    ) {
      if (0 == index $target, $code) {
        $from = $self->numbers->{$code};
        last;
      }
    }

    $from = $self->numbers->{1};
  }

  my $sid = $self->sid;
  my $res = $self->http_post(
    "https://api.twilio.com/2010-04-01/Accounts/$sid/SMS/Messages",
    Content => [
      From => $from,
      To   => $target,
      Body => $text,
    ],
    Authorization => "Basic " . $self->auth,
  );

  unless ($res->is_success) {
    warn "failed to send sms to $target: " . $res->as_string;
  }

  return $res;
}

sub describe_event ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $event->from_address;
  return "an sms from $who";
}

1;
