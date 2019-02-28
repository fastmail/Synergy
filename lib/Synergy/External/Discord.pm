use v5.24.0;
use warnings;
package Synergy::External::Discord;

use Moose;
use experimental qw(lexical_subs signatures);
use namespace::autoclean;
use utf8;

use JSON::MaybeXS;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::Async::WebSocket::Client;
use List::AllUtils qw(part);
use Data::Dumper::Concise;

use Synergy::Logger '$Logger';

my $JSON = JSON->new;

with 'Synergy::Role::HubComponent';

has bot_token => ( is => 'ro', required => 1 );

has connected => (
  is => 'rw',
  isa => 'Bool',
  default => '0',
);

has _heartbeat_timer => (
  is => 'rw',
  predicate => '_has_heartbeat_timer',
);

has _last_heartbeat_ack => (
  is      => 'rw',
  isa     => 'Int',
  default => sub { time },
);

has _sequence => (
  is => 'rw',
  isa => 'Int',
);

has on_event => (
  is => 'ro',
  isa => 'CodeRef',
  default => sub { sub {} },
);

has users => (
  is => 'ro',
  isa => 'HashRef',
  writer => '_set_users',
);

has channels => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
  traits => [ 'Hash' ],
  handles => {
    is_channel   => 'exists',
    get_channel  => 'get',
    _set_channel => 'set',
  },
);
sub set_channel ($self, $channel) {
  die "E: set_channel takes a type 0 channel object" unless $channel->{type} == 0;
  return if $self->is_channel($channel->{id});
  $Logger->log("discord: adding channel: $channel->{name} ($channel->{id})");
  $self->_set_channel($channel->{id} => $channel);
}

has dm_channels => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
  traits => [ 'Hash' ],
  handles => {
    is_dm_channel   => 'exists',
    get_dm_channel  => 'get',
    _set_dm_channel => 'set',
  },
);
sub set_dm_channel ($self, $channel) {
  die "E: set_dm_channel takes a type 1 channel object" unless $channel->{type} == 1;
  return if $self->is_dm_channel($channel->{id});
  $Logger->log("discord: adding DM channel ($channel->{id})");
  $self->_set_dm_channel($channel->{id} => $channel);
}

has group_conversations => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
  traits => [ 'Hash' ],
  handles => {
    is_group_conversation   => 'exists',
    get_group_conversation  => 'get',
    _set_group_conversation => 'set',
  },
);
sub set_group_conversation ($self, $channel) {
  die "E: set_group_conversation takes a type 3 channel object" unless $channel->{type} == 3;
  return if $self->set_group_conversation($channel->{id});
  $Logger->log("discord: adding group conversation $channel->{name} ($channel->{id})");
  $self->_set_group_conversation($channel->{id} => $channel);
}

has client => (
  is       => 'ro',
  required => 1,
  lazy     => 1,
  default  => sub ($self) {
    my $client = Net::Async::WebSocket::Client->new(
      on_text_frame => sub {
        my $frame = $_[1];

        my $event;
        unless (eval { $event = $JSON->decode($frame) }) {
          $Logger->log("discord: error decoding frame content: <$frame> <$@>");
          return;
        }

        $self->handle_event($event);
      },
    );
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

has guild_id => (
  is => 'ro',
  isa => 'Str',
  writer => '_set_guild_id',
);

sub connect ($self) {
  $self->connected(0);

  $self->hub->http
            ->GET("https://discordapp.com/api/gateway")
            ->on_done(sub ($res) { $self->_register_discord_rtg($res) })
            ->on_fail(sub ($err) { die "couldn't start RTG API: $err" })
            ->get;
};

sub _register_discord_rtg ($self, $res) {
  my $json = decode_json($res->content);

  my $wss_url = $json->{url};

  $Logger->log("discord: connecting to RTG: $wss_url");

  $self->loop->add($self->client);
  $self->client->connect(
    url => $wss_url,
    service => 'https',
    on_connected => sub {
      $Logger->log("discord: connected to RTG");
    },
  );
}

sub handle_event ($self, $event) {
  #warn Dumper($event);

  my ($opcode, $data, $sequence, $name) = @$event{qw(op d s t)};

  $self->_sequence($sequence) if defined $sequence;

  # https://discordapp.com/developers/docs/topics/opcodes-and-status-codes
  state $opcode_handlers = {
    0  => \&handle_dispatch,
    1  => \&handle_hearbeat,
    7  => \&handle_reconnect,
    9  => \&handle_invalid_session,
    10 => \&handle_hello,
    11 => \&handle_heartbeat_ack,
  };

  my $handler = $opcode_handlers->{$opcode};
  unless ($handler) {
    $Logger->log("discord: no handler for opcode $opcode, data: ".encode_json($data));
    return;
  }

  $handler->($self, $data, $name);
}

sub handle_dispatch {
  my ($self, $data, $name) = @_;
  
  if ($name eq 'READY') {
    $self->_set_own_id($data->{user}{id});
    $self->_set_own_name($data->{user}{username});
    $self->_set_guild_id($data->{guilds}->[0]->{id}); # XXX support multiple guilds someday?

    $Logger->log("discord: ready for service, I am $data->{user}{username} ($data->{user}{id})");

    $self->load_users;
    $self->load_channels;

    $self->connected(1);
    return;
  }

  if ($name eq 'CHANNEL_CREATE') {
    if ($data->{type} == 0) {
      $self->set_channel($data);
    }
    elsif ($data->{type} == 1) {
      $self->set_dm_channel($data);
    }
    elsif ($data->{type} == 3) {
      $self->set_group_conversation($data);
    }
    else {
      $Logger->log("discord: no support for type $data->{type} channel");
    }
    return;
  }

  # XXX probably too low-level, could make some objects based on the event name or something
  $self->on_event->($name, $data);
}

sub handle_heartbeat {
  my ($self, $data) = @_;

  $Logger->log("discord: handle_heartbeat: unimplemented");
}

sub handle_reconnect {
  my ($self, $data) = @_;

  $Logger->log("discord: handle_reconnect: unimplemented");
}

sub handle_invalid_session {
  my ($self, $data) = @_;

  $Logger->log("discord: handle_invalid_session: unimplemented");
}

sub handle_hello {
  my ($self, $data) = @_;

  my $interval = int($data->{heartbeat_interval}/1000);

  if ($self->_has_heartbeat_timer) {
    # remove any previous timer
    $self->loop->remove($self->_heartbeat_timer);
  }

  my $timer = IO::Async::Timer::Periodic->new(
    interval => $interval,
    on_tick => sub {
      if ($self->_last_heartbeat_ack + $interval < time) {
        $Logger->log("discord: previous heartbeat was never acknowledged");
        # XXX reconnect
      }
      $self->send_heartbeat;
    },
  );

  $timer->start;
  $self->loop->add($timer);

  $self->_heartbeat_timer($timer);

  $Logger->log("discord: hello! heartbeat interval set to $interval ms");

  $self->send_identify;
}

sub handle_heartbeat_ack {
  my ($self, $data) = @_;
  $self->_last_heartbeat_ack(time);
}

sub send_identify {
  my ($self) = @_;

  $Logger->log("discord: sending identify");
  my $frame = encode_json({
    op => 2,
    d  => {
      token      => $self->bot_token,
      properties => {
        '$os'      => 'linux',
        '$browser' => 'Synergy',
        '$device'  => 'Synergy',
      },
    },
  });
  #$Logger->log("discord: identify frame: $frame");
  $self->client->send_text_frame($frame);
}

sub send_heartbeat {
  my ($self) = @_;
  #$Logger->log("discord: sending heartbeat");
  my $frame = encode_json({
    op => 1,
    d  => $self->_sequence
  });
  #$Logger->log("discord: heartbeat frame: $frame");
  $self->client->send_text_frame($frame);
}

sub send_message ($self, $channel_id, $text, $alts = {}) {
  my $http_future = $self->api_post("/channels/$channel_id/messages", {
    content => $text,
    # XXX attachments and stuff
  });
}

sub api_post ($self, $endpoint, $arg = {}) {
  my $url = "https://discordapp.com/api$endpoint";
  return Future->wrap(
    $self->hub->http->POST(
      URI->new($url), 
      $arg,
      headers => {
        'Authorization' => 'Bot '.$self->bot_token,
      },
    )
  );
}

sub api_get ($self, $endpoint, $arg = {}) {
  my $u = URI->new("https://discordapp.com/api$endpoint");
  $u->query_param($_ => $arg->{$_}) for sort keys %$arg;
  return Future->wrap(
    $self->hub->http->GET(
      $u,
      headers => {
        'Authorization' => 'Bot '.$self->bot_token,
      },
    )
  );
}

sub username ($self, $id) {
  return $self->users->{$id}{user}{username};
}

has loaded_users => (is => 'rw', isa => 'Bool');
has loaded_channels => (is => 'rw', isa => 'Bool');

has _is_ready => (is => 'rw', isa => 'Bool');

sub is_ready ($self) {
  return 1 if $self->_is_ready;

  # Stupid micro-opt
  if (
       $self->loaded_users
    && $self->loaded_channels
  ) {
    $self->_is_ready(1);
  }

  return $self->_is_ready;
}

sub load_users ($self) {
  my $guild_id = $self->guild_id;
  $self->api_get("/guilds/$guild_id/members", {
    limit => 1000,
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content);
    $self->_set_users({
      map { $_->{user}{id} => $_ } @$res,
    });
    $Logger->log("discord: users loaded");

    $self->loaded_users(1);
  });
}

sub load_channels ($self) {
  my $guild_id = $self->guild_id;
  $self->api_get("/guilds/$guild_id/channels")
  ->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content);
    my ($channels, $dms, $voice_channels, $group_dms) = part { $_->{type} } @$res;
    $self->set_channel($_) for @$channels;
    $self->set_dm_channel($_) for @$dms;
    $self->set_group_conversation($_) for @$group_dms;
    $Logger->log("discord: channels loaded");

    $self->loaded_channels(1);
  });
}

1;
