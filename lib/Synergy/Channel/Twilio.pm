use v5.24.0;
package Synergy::Channel::Twilio;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS qw(encode_json decode_json);

use Synergy::Logger '$Logger';

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

has http_path => (
  is  => 'ro',
  isa => 'Str',
  default => '/sms',
);

sub start ($self) {
  $self->hub->server->register_path($self->http_path, sub ($req) {
    my $param = $req->parameters;
    my $from  = $param->{From} // '';

    unless (($param->{AccountSid}//'') eq $self->sid) {
      $Logger->log([
        "Bad request (wrong sid) for %s from phone %s from IP %s",
        $req->uri->path_query,
        $from,
        $req->address,
      ]);

      return [
        400,
        [ 'Content-Type', 'application/json' ],
        [ "{}\n" ],
      ];
    }

    my $who = $self->hub->user_directory->user_by_channel_and_address(
      $self,
      $from,
    );

    unless ($who) {
      my (@match) = grep {; $_->has_phone && $_->phone eq $from }
                    $self->hub->user_directory->users;

      if (@match == 1) {
        $who = $match[0];
        $Logger->log([
          "resolved %s to %s via phone number",
          $from,
          $who->username,
        ]);
      } elsif (@match > 1) {
        $Logger->log([ "phone number %s is ambiguous", $from ]);
      }
    }

    unless ($who) {
      $Logger->log([
        "Bad request (unknown user) for %s from phone %s from IP %s",
        $req->uri->path_query,
        $from,
        $req->address,
      ]);

      return [
        400,
        [ 'Content-Type', 'application/json' ],
        [ "{}\n" ],
      ];
    }

    my $text = $param->{Body};

    my $evt = Synergy::Event->new({
      type => 'message',
      text => $text,
      was_targeted => 1,
      is_public    => 0,
      from_channel => $self,
      from_address => $from,
      from_user    => $who, # we already gave up if no user -- rjbs, 2018-03-15
      transport_data => $param,
      conversation_address => $from,
    });

    my $rch = Synergy::ReplyChannel->new(
      channel => $self,
      default_address => $from,
      private_address => $from,
    );

    $self->hub->handle_event($evt, $rch);

    return [ 200, [ 'Content-Type', 'text/plain' ], [ "" ] ];
  });
}

sub http_post {
  my $self = shift;
  return $self->hub->http_request('POST' => @_);
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  unless ($user->phone) {
    $Logger->log([
      "can't send message, no phone number for %s",
      $user->username,
    ]);
    return;
  }

  my $where = $user->phone;

  $Logger->log([ "sending text <$text> to $where" ]);
  $self->send_message($where, $text, $alts);
}

sub send_message ($self, $target, $text, $alts) {
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
    "https://api.twilio.com/2010-04-01/Accounts/$sid/Messages.json",
    Content => [
      From => $from,
      To   => $target,
      Body => $text,
    ],
    Authorization => "Basic " . $self->auth,
  );

  unless ($res->is_success) {
    $Logger->log("failed to send sms to $target: " . $res->as_string);
  }

  return $res;
}

sub describe_event ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $event->from_address;
  return "an sms from $who";
}

1;
