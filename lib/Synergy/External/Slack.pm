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

use Synergy::Logger '$Logger';

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

has dm_channels => (
  is      => 'ro',
  isa     => 'HashRef',
  traits  => [ 'Hash' ],
  writer  => '_set_dm_channels',
  default => sub { {} },
  handles => {
    dm_channel_for      => 'get',
    is_known_dm_channel => 'exists',
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
  $self->load_dm_channels;
}

sub username ($self, $id) {
  return $self->users->{$id}->{name};
}

sub dm_channel_for_user ($self, $user, $channel) {
  my $identity = $user->identities->{$channel->name};
  unless ($identity) {
    warn "No known identity for " . $user->username . " for channel " . $self->name . "\n";

    return;
  }

  return $self->dm_channel_for_address($identity);
}

sub dm_channel_for_address ($self, $slack_id) {
  my $channel_id = $self->dm_channel_for($slack_id);
  return $channel_id if $self->is_known_dm_channel($slack_id);

  # look it up!
  my $res = $self->api_call('im.open', { user => $slack_id })->get;
  return unless $res->is_success;

  my $json = decode_json($res->decoded_content);

  $channel_id = $json->{ok}                       ? $json->{channel}->{id}
              : $json->{error} eq 'cannot_dm_bot' ? undef
              : '0E0';

  if (defined $channel_id && $channel_id eq '0E0') {
    $Logger->log([
      "weird error from slack: %s",
      $json,
    ]);
    return;
  }

  # don't look it up again!
  $self->dm_channels->{$slack_id} = $channel_id;
  return $channel_id;
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

sub load_dm_channels ($self) {
  $self->api_call('im.list', {})->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content);
    $self->_set_dm_channels({
      map { $_->{user}, $_->{id} } $res->{ims}->@*
    });
  });
}

1;
