use v5.36.0;
package Synergy::Channel::Twilio;

use Moose;
use JSON::MaybeXS qw(encode_json decode_json);

use Synergy::Logger '$Logger';

use Synergy::Event;

use namespace::autoclean;

with 'Synergy::Role::Channel';
with 'Synergy::Role::HTTPEndpoint';

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

has '+http_path' => (
  default => '/sms',
);

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

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

  $self->hub->handle_event($evt);

  return [ 200, [ 'Content-Type', 'text/plain' ], [ "" ] ];
}

sub http_post {
  my $self = shift;
  return $self->hub->http_request('POST' => @_);
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  my $phone = $user->identity_for($self->name) // $user->phone;

  unless ($phone) {
    $Logger->log([
      "can't send message, no phone number for %s",
      $user->username,
    ]);
    return;
  }

  $Logger->log([ "sending text <$text> to $phone" ]);
  $self->send_message($phone, $text, $alts);
}

my %LANGUAGE_FOR = (
  61 => 'en-AU',
);

sub send_message ($self, $target, $text, $alts = {}) {
  my $from = $self->from;

  my $picked_code;

  for my $code (sort { length $b <=> length $a } keys $self->numbers->%*) {
    if ($target =~ /\A\+?\Q$code/) {
      $from = $self->numbers->{$code};
      $picked_code = $code;
      last;
    }
  }

  my $sid = $self->sid;
  my $res_f;

  if ($alts->{voice}) {
    my $language = $LANGUAGE_FOR{ $picked_code // 1 } // 'en-US';

    my $encoded = join q{},
      map {; "<![CDATA[$_]]>" } split /(\]\])/, $alts->{voice};

    $res_f = $self->http_post(
      "https://api.twilio.com/2010-04-01/Accounts/$sid/Calls.json",
      Content => [
        From => $from,
        To   => $target,
        Twiml => <<~"END"
          <Response>
            <Say language="$language" loop="3" voice="woman">$encoded</Say>
          </Response>
        END
      ],
      Authorization => "Basic " . $self->auth,
    );
  } else {
    $res_f = $self->http_post(
      "https://api.twilio.com/2010-04-01/Accounts/$sid/Messages.json",
      Content => [
        From => $from,
        To   => $target,
        Body => $text,
      ],
      Authorization => "Basic " . $self->auth,
    );
  }

  return $res_f->then(sub ($res) {
    if ($res->is_success) {
      my $req_id   = $res->header('Twilio-Request-Id');
      my $res_json = $res->decoded_content;
      $Logger->log("sent sms to $target as req $req_id; response JSON: $res_json");
    } else {
      $Logger->log("failed to send sms to $target: " . $res->as_string);
    }
  })->retain;
}

sub describe_event ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $event->from_address;
  return "an sms from $who";
}

sub describe_conversation ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $event->from_address;
  return $who;
}

1;
