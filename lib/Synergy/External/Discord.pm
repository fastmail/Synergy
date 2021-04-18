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
use Time::HiRes ();

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
  clearer   => '_clear_heartbeat_timer',
);

before _clear_heartbeat_timer => sub ($self, @) {
  if ($self->_has_heartbeat_timer) {
    $self->loop->remove($self->_heartbeat_timer);
  }
};

has _waiting_for_heartbeat_ack_since => (
  is      => 'rw',
  isa     => 'Num',
  clearer => '_clear_waiting_for_heartbeat_ack_since',
);

has _last_heartbeat_acked_at => (
  is  => 'rw',
  isa => 'Num',
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
  $Logger->log_fatal("ERROR: set_channel takes a type 0 channel object")
    unless $channel->{type} == 0;

  return if $self->is_channel($channel->{id});

  $Logger->log("Discord: adding channel: $channel->{name} ($channel->{id})");
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
  $Logger->log_fatal("ERROR: set_dm_channel takes a type 1 channel object")
    unless $channel->{type} == 1;

  return if $self->is_dm_channel($channel->{id});

  $Logger->log("Discord: adding DM channel ($channel->{id})");
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
  $Logger->log_fatal("ERROR: set_group_conversation takes a type 3 channel object")
    unless $channel->{type} == 3;

  return if $self->set_group_conversation($channel->{id});

  $Logger->log("Discord: adding group conversation $channel->{name} ($channel->{id})");
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
          $Logger->log("Discord: error decoding frame content: <$frame> <$@>");
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

  $self->hub->http_client
            ->GET("https://discordapp.com/api/gateway")
            ->on_done(sub ($res) { $self->_register_discord_rtg($res) })
            ->on_fail(sub ($err) { die "couldn't start RTG API: $err" })
            ->get;
};

sub _register_discord_rtg ($self, $res) {
  my $json = decode_json($res->content);

  my $wss_url = $json->{url};

  $Logger->log("Discord: connecting to RTG: $wss_url");

  $self->loop->add($self->client);
  $self->client->connect(
    url => $wss_url,
    service => 'https',
    on_connected => sub {
      $Logger->log("Discord: connected to RTG");
    },
  );
}

sub handle_event ($self, $event) {
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
    $Logger->log([
      "Discord: no handler for opcode $opcode, data: %s",
      $data,
    ]);
    return;
  }

  $handler->($self, $data, $name);
}

sub handle_dispatch {
  my ($self, $data, $name) = @_;

  if ($name eq 'READY') {
    $Logger->log_debug([ "Discord ready: %s", $data ]);

    $self->_set_own_id($data->{user}{id});
    $self->_set_own_name($data->{user}{username});
    $self->_set_guild_id($data->{guilds}->[0]->{id}); # XXX support multiple guilds someday?

    $Logger->log("Discord: ready for service, I am $data->{user}{username} ($data->{user}{id})");

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
      $Logger->log("Discord: no support for type $data->{type} channel");
    }
    return;
  }

  # XXX probably too low-level, could make some objects based on the event name or something
  $self->on_event->($name, $data);
}

sub handle_heartbeat {
  my ($self, $data) = @_;

  $Logger->log("Discord: handle_heartbeat: unimplemented");
}

sub handle_reconnect {
  my ($self, $data) = @_;

  $Logger->log("Discord: handle_reconnect: attempting to reconnect");
  $self->loop->remove($self->client);

  $self->_clear_heartbeat_timer;

  $self->connect;
}

sub handle_invalid_session {
  my ($self, $data) = @_;

  $Logger->log("Discord: handle_invalid_session: unimplemented");
}

sub handle_hello {
  my ($self, $data) = @_;

  my $interval = int($data->{heartbeat_interval}/1000);

  $self->_clear_heartbeat_timer;

  my $timer = IO::Async::Timer::Periodic->new(
    interval  => $interval,
    on_tick   => sub { $self->send_heartbeat; },
  );

  $timer->start;
  $self->loop->add($timer);

  $self->_heartbeat_timer($timer);

  $Logger->log([ 'Discord: hello! heartbeat interval set to %s', $interval ]);

  $self->send_identify;
}

sub handle_heartbeat_ack {
  my ($self, $data) = @_;

  my $now   = Time::HiRes::time();
  my $since = $self->_waiting_for_heartbeat_ack_since;
  $self->_last_heartbeat_acked_at($now);

  my $ago = $now - $since;
  $Logger->log_debug([
    "heartbeat (sent %0.4fs ago) has been acked",
    $ago,
  ]);

  $self->_clear_waiting_for_heartbeat_ack_since;

  return;
}

sub send_identify {
  my ($self) = @_;

  $Logger->log("Discord: sending identify");
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
  $Logger->log_debug([ "Discord: identify frame: %s", $frame ]);
  $self->client->send_text_frame($frame);
}

sub send_heartbeat {
  my ($self) = @_;

  if (my $since = $self->_waiting_for_heartbeat_ack_since) {
    my $msg  = sprintf "heartbeat sent at %s was never acked", $since;

    if (my $last = $self->_last_heartbeat_acked_at) {
      my $now  = Time::HiRes::time();
      my $ago  = $now - $last;

      $Logger->log([ "$msg; last heartbeat ack %0.4fs ago", $ago ]);
    } else {
      $Logger->log("$msg; no heartbeat has ever been acked");
    }
  }

  my $frame = encode_json({
    op => 1,
    d  => $self->_sequence
  });

  $self->client->send_text_frame($frame);
  $self->_waiting_for_heartbeat_ack_since(Time::HiRes::time());

  return;
}

sub send_message ($self, $channel_id, $text, $alts = {}) {
  if (my $r = $alts->{discord_reaction}) {
    # This code is mostly stolen from the Slack external.
    # -- rjbs, 2020-05-17
    my $e = $r->{event};

    if ( $e
      && $e->from_channel->isa('Synergy::Channel::Discord')
      && $e->from_channel->discord == $self
    ) {
      my $remove = $r->{reaction} =~ s/^-//;

      my $http_future;
      if ($remove) {
        $http_future = $self->api_delete(
            '/channels/' . $e->conversation_address
          . '/messages/' . $e->transport_data->{id}
          . '/reactions/' . URI::Escape::uri_escape_utf8($r->{reaction}) . '/@me'
        );
      } else {
        $http_future = $self->api_put(
            '/channels/' . $e->conversation_address
          . '/messages/' . $e->transport_data->{id}
          . '/reactions/' . URI::Escape::uri_escape_utf8($r->{reaction}) . '/@me'
        );
      }

      my $f = $self->loop->new_future;
      $http_future->on_done(sub ($http_res) {
        my $res = {};
        $f->done({
          type => 'discord',
          transport_data => $res
        });
      });

      return $f;
    }
  }

  my $http_future = $self->api_post("/channels/$channel_id/messages", {
    content => $text,
    # XXX attachments and stuff
  });
}

sub api_post ($self, $endpoint, $arg = {}) {
  my $url = "https://discordapp.com/api$endpoint";
  return Future->wrap(
    $self->hub->http_client->POST(
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
    $self->hub->http_client->GET(
      $u,
      headers => {
        'Authorization' => 'Bot '.$self->bot_token,
      },
    )
  );
}

sub api_delete ($self, $endpoint, $arg = {}) {
  my $u = URI->new("https://discordapp.com/api$endpoint");
  return Future->wrap(
    $self->hub->http_client->DELETE(
      $u,
      headers => {
        'Authorization' => 'Bot '.$self->bot_token,
      },
    )
  );
}

sub api_put ($self, $endpoint, $arg = {}) {
  my $u = URI->new("https://discordapp.com/api$endpoint");
  return Future->wrap(
    $self->hub->http_client->PUT(
      $u,
      q{},
      content_type => 'text/plain',
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
    my $json = $http_res->decoded_content(charset => undef);
    my $res  = decode_json($json);

    $Logger->log("Discord: users loaded");
    $Logger->log_debug([ 'Discord: user list: %s', $res ]);

    $self->_set_users({
      map { $_->{user}{id} => $_ } @$res,
    });

    $self->loaded_users(1);
  });
}

sub load_channels ($self) {
  my $guild_id = $self->guild_id;
  $self->api_get("/guilds/$guild_id/channels")->on_done(sub ($http_res) {
    my $json = $http_res->decoded_content(charset => undef);
    my $res  = decode_json($json);

    my ($channels, $dms, $voice_channels, $group_dms) = part { $_->{type} } @$res;
    $self->set_channel($_) for @$channels;
    $self->set_dm_channel($_) for @$dms;
    $self->set_group_conversation($_) for @$group_dms;

    $Logger->log("Discord: channels loaded");

    $self->loaded_channels(1);
  });
}

1;
