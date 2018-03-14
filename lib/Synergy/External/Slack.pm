use v5.24.0;
package Synergy::External::Slack;

use Moose;
use experimental qw(lexical_subs signatures);
use namespace::autoclean;

use Cpanel::JSON::XS qw(decode_json encode_json);
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::Async::WebSocket::Client;
use Data::Dumper::Concise;

has loop    => (
  is => 'ro',
  required => 1
);

has http    => (
  is => 'ro',
  isa => 'Net::Async::HTTP',
  init_arg => undef,
  default => sub { Net::Async::HTTP->new },
);

has api_key => ( is => 'ro', required => 1 );

has users => (
  is => 'ro',
  isa => 'HashRef',
  writer => '_set_users',
);

has channels => (
  is => 'ro',
  isa => 'HashRef',
  writer => '_set_channels',
);

has _channels_by_name => (
  is              => 'ro',
  isa             => 'HashRef',
  traits          => [ 'Hash' ],
  lazy            => 1,
  handles         => {
    channel_named => 'get',
  },
  default         => sub ($self) {
    my %by_name;
    for my $k (keys $self->channels->%*) {
      $by_name{ $self->channels->{ $k }{name} } = $self->channels->{ $k };
    }

    return \%by_name;
  },
);

has client => (
  is       => 'ro',
  required => 1,
  lazy     => 1,
  default  => sub {
    my $client = Net::Async::WebSocket::Client->new;
  },
);

has own_name => (
  is => 'ro',
  isa => 'Str',
  writer => '_set_own_name',
);

has own_id => (
  is => 'ro',
  isa => 'Str',
  writer => '_set_own_id',
);

sub connect ($self) {
  $self->loop->add($self->http);
  $self->http
       ->GET("https://slack.com/api/rtm.connect?token=" . $self->api_key)
       ->on_done(sub ($res) { $self->_register_slack_rtm($res) })
       ->on_fail(sub ($err) { die "couldn't start RTM API: $err" })
       ->get;
};

sub send_frame ($self, $frame) {
  state $i = 1;

  $frame->{id} = $i++;

  $self->client->send_frame(masked => 1, buffer => encode_json($frame));
}

sub send_message ($self, $channel, $text) {
  $self->send_frame({
    type => 'message',
    channel => $channel,
    text    => $text,
  });
}

sub _register_slack_rtm ($self, $res) {
  my $json = decode_json($res->content);

  die "Could not connect to Slack RTM: $json->{error}"
    unless $json->{ok};

  $self->_set_own_name($json->{self}->{name});
  $self->_set_own_id($json->{self}->{id});

  $self->loop->add($self->client);
  $self->client->connect(
    url => $json->{url},
    service => 'https',
    on_connected => sub {
      state $i = 1;

      # Send pings to slack so it knows we're still alive
      my $timer = IO::Async::Timer::Periodic->new(
        interval => 10,
        on_tick  => sub {
          $self->send_frame({
            type => 'ping',
          });
        }
      );

      $timer->start;
      $self->loop->add($timer);
    },
  );
}

# This returns a Future. If you're just posting or something, you can just let
# it complete whenever. If you're retrieving data, you probably want to do
# something like slack_call($method, {})->on_done(sub { do_something }).
sub api_call ($self, $method, $arg = {}) {
  my $url = "https://slack.com/api/$method";
  my $payload = {
    token => $self->api_key,
    %$arg,
  };

  return Future->wrap($self->http->POST(URI->new($url), $payload));
}

sub setup ($self) {
  say "Connected to Slack!";
  $self->load_users;
  $self->load_channels;
}

sub username ($self, $id) {
  return $self->users->{$id}->{name};
}

sub load_users ($self) {
  $self->api_call('users.list', {
    presence => 0,
    callback => sub ($resp) {
    },
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content);
    $self->_set_users({
      map { $_->{id} => $_ } $res->{members}->@*
    });
  });
}

sub load_channels ($self) {
  $self->api_call('channels.list', {
    exclude_archived => 1,
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content);
    $self->_set_channels({
      map { $_->{id}, $_ } $res->{channels}->@*
    });
  });
}

1;
