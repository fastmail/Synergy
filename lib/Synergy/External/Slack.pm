use v5.28.0;
use warnings;
package Synergy::External::Slack;

use Moose;
use experimental qw(lexical_subs signatures);
use namespace::autoclean;
use utf8;

use Cpanel::JSON::XS qw(decode_json encode_json);
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::Async::WebSocket::Client;
use Data::Dumper::Concise;

use Synergy::Logger '$Logger';

with 'Synergy::Role::HubComponent';

has api_key => ( is => 'ro', required => 1 );

has privileged_api_key => (
  is => 'ro',
  lazy => 1,
  default => sub { $_[0]->api_key },
);

has connected => (
  is => 'rw',
  isa => 'Bool',
  default => '0',
);

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

has group_conversations => (
  is => 'ro',
  isa => 'HashRef',
  writer => '_set_group_conversations',
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

has _team_data => (
  is => 'ro',
  writer => '_set_team_data',
);

has pending_frames => (
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  default => sub { {} },
);

has pending_timeouts => (
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  default => sub { {} },
);

sub connect ($self) {
  $self->connected(0);

  $self->hub->http_client
            ->GET("https://slack.com/api/rtm.connect?token=" . $self->api_key)
            ->on_done(sub ($res) { $self->_register_slack_rtm($res) })
            ->on_fail(sub { die "couldn't start RTM API: @_" })
            ->get;
};

sub send_frame ($self, $frame) {
  state $i = 1;
  my $frame_id = $i++;
  $frame->{id} = $frame_id;

  if ($self->connected) {
    $self->client->send_frame(masked => 1, buffer => encode_json($frame));
  } else {
    # Save it til after we've successfully reconnected
    $self->queue_frame($frame);
  }

  my $f = $self->loop->new_future;
  $self->pending_frames->{$frame_id} = $f;

  my $timeout = $self->loop->timeout_future(after => 3);
  $timeout->on_fail(sub {
    $Logger->log("failed to get response from slack; trying to reconnect");

    $self->client->close;
    $self->connect;

    # Also fail any pending futures for this frame.
    my $f = delete $self->pending_frames->{$frame_id};
    $f->fail("timed out on connection to slack")  if $f;
  });

  $self->pending_timeouts->{$frame_id} = $timeout;

  return $f;
}

sub handle_frame ($self, $slack_event) {
  return unless my $reply_to = $slack_event->{reply_to};

  # Cancel the timeout, then mark the future done with the decoded frame
  # object.
  my $timeout = delete $self->pending_timeouts->{$reply_to};
  $timeout->cancel if $timeout;

  my $f = delete $self->pending_frames->{$reply_to};
  return unless $f;

  $f->done({
    type => 'slack',
    transport_data => $slack_event,
  });
}

has _frame_queue => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => [ 'Array' ],
  lazy    => 1,
  handles => {
    _next_frame       => 'shift',
    queue_frame       => 'push',
    has_queued_frames => 'count',
  },
  default => sub { [] },
);

sub flush_queue ($self) {
  while ($self->has_queued_frames) {
    $self->client->send_frame(
      masked => 1,
      buffer => encode_json($self->_next_frame)
    );
  }
}

sub send_message ($self, $channel, $text, $alts = {}) {
  if (my $r = $alts->{slack_reaction}) {
    # For annoying reasons, and only for now (I hope), a slack_reaction
    # alternative must include the inciting event.  If it doesn't, we can't
    # find the message to which we react!  If we don't have the event, or if
    # the event isn't from Slack, we'll fall back. -- rjbs, 2018-06-13
    my $e = $r->{event};

    if ( $e
      && $e->from_channel->isa('Synergy::Channel::Slack')
      && $e->from_channel->slack == $self # O_O -- rjbs, 2018-06-13
    ) {
      my $remove = $r->{reaction} =~ s/^-//;

      my $http_future = $self->api_call(
        ($remove ? 'reactions.remove' : 'reactions.add'),
        {
          name      => $r->{reaction},
          channel   => $e->transport_data->{channel},
          timestamp => $e->transport_data->{ts},
        }
      );

      my $f = $self->loop->new_future;
      $http_future->on_done(sub ($http_res) {
        my $res = decode_json($http_res->decoded_content(charset => undef));
        $f->done({
          type => 'slack',
          transport_data => $res
        });
      });

      return $f;
    }
  }

  return $self->_send_rich_text($channel, $alts->{slack})
    if $alts->{slack};

  return $self->_send_plain_text($channel, $text);
}

sub _send_plain_text ($self, $channel, $text) {
  # chat.postMessage is quite happy to send to a USER address
  # (U[...]), but we need to send to a DM address (D[...])
  if ($channel =~ /^U/) {
    $channel = $self->dm_channel_for_address($channel);
  }

  my $f = $self->send_frame({
    type => 'message',
    channel => $channel,
    text    => $text,
  });

  return $f;
}

sub _send_rich_text ($self, $channel, $rich) {
  my $http_future = $self->api_call('chat.postMessage', {
    (ref $rich ? (%$rich) : (text => $rich)),
    channel => $channel,
    as_user => \1,
  });

  my $f = $self->loop->new_future;
  $http_future->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content(charset => undef));
    $f->done({
      type => 'slack',
      transport_data => $res
    });
  });

  return $f;
}

sub send_file ($self, $channel, $filename, $content) {
  my $post_args = [ # arrayref for form data
    channels => [$channel],
    filename => $filename,
    content  => $content,
  ];

  my $http_future = Future->wrap($self->hub->http_client->POST(
    URI->new($self->_api_url('files.upload')),
    $post_args,
    content_type => 'application/x-www-form-urlencoded',
    headers => [
      $self->_api_auth_header,
    ],
  ));

  my $f = $self->loop->new_future;
  $http_future->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content(charset => undef));
    $f->done({
      type => 'slack',
      transport_data => $res
    });
  });

  return $f;
}

sub _register_slack_rtm ($self, $res) {
  my $json = decode_json($res->content);

  die "Could not connect to Slack RTM: $json->{error}"
    unless $json->{ok};

  # This is a dumb hack: when I converted synergy to a Slack app, I gave her
  # perms to add a user with the name "synergee" because I thought "synergy"
  # would conflict. So now "synergee ++ do a thing" works, which is not ideal,
  # since we use often that as a way of joking about making tasks we'd never
  # do. I *think* that reinstalling the app to our workspace would fix this,
  # but I'm not entirely sure and I don't want to make everyone open yet
  # another DM with synergy, so here we are. -- michael, 2019-06-03
  my $our_name = $json->{self}->{name};
  $our_name = 'synergy' if $our_name eq 'synergee';

  $self->_set_own_name($our_name);
  $self->_set_own_id($json->{self}->{id});
  $self->_set_team_data($json->{team});

  $self->loop->add($self->client);
  $self->client->connect(
    url => $json->{url},
    service => 'https',
    on_connected => sub {
      $self->connected(1);

      $self->flush_queue;

      state $i = 1;

      # Send pings to slack so it knows we're still alive
      my $timer = IO::Async::Timer::Periodic->new(
        notifier_name => 'slack-ping',
        interval => 10,
        on_tick  => sub {
          $self->send_frame({ type => 'ping' });
        }
      );

      $timer->start;
      $self->loop->add($timer);
    },
  );
}

sub _api_url ($self, $method) {
  return "https://slack.com/api/$method";
}
sub _api_auth_header ($self) {
  return (Authorization => 'Bearer ' . $self->api_key);
}
sub _privileged_api_auth_header ($self) {
  return (Authorization => 'Bearer ' . $self->privileged_api_key);
}

# This returns a Future. If you're just posting or something, you can just let
# it complete whenever. If you're retrieving data, you probably want to do
# something like slack_call($method, {})->on_done(sub { do_something }).
sub api_call ($self, $method, $arg = {}, %extra) {
  my $url = $self->_api_url($method);

  return $self->_form_encoded_api_call($url, $arg, %extra)
    if delete $arg->{form_encoded};

  my $json = encode_json($arg);

  my @auth = $extra{privileged}
           ? $self->_privileged_api_auth_header
           : $self->_api_auth_header;

  return Future->wrap($self->hub->http_client->POST(
    URI->new($url),
    $json,
    content_type => 'application/json; charset=utf-8',
    headers => [
      @auth,
    ],
  ));
}

# I mean honestly, slack.
sub _form_encoded_api_call ($self, $url, $arg, %extra) {
  return Future->wrap($self->hub->http_client->POST(
    URI->new($url),
    [ %$arg ],
    # content_type => 'application/json; charset=utf-8',
    headers => [
      $self->_api_auth_header,
    ],
  ));
}

sub setup ($self) {
  $Logger->log("Connected to Slack!");
  $self->load_users;
  $self->load_channels;
  $self->load_group_conversations;
  $self->load_dm_channels;
}

sub username ($self, $id) {
  return $self->users->{$id}->{name};
}

sub dm_channel_for_user ($self, $user, $channel) {
  my $identity = $user->identity_for($channel->name);
  unless ($identity) {
    $Logger->log([
      "No known identity for %s for channel %s",
      $user->username,
      $self->name,
    ]);

    return;
  }

  return $self->dm_channel_for_address($identity);
}

sub dm_channel_for_address ($self, $slack_id) {
  my $channel_id = $self->dm_channel_for($slack_id);
  return $channel_id if $self->is_known_dm_channel($slack_id);

  # look it up!
  my $res = $self->api_call('conversations.open', {
    users => $slack_id,
  })->get;

  return unless $res->is_success;

  my $json = decode_json($res->decoded_content(charset => undef));

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

has loaded_users => (is => 'rw', isa => 'Bool');
has loaded_channels => (is => 'rw', isa => 'Bool');
has loaded_dm_channels => (is => 'rw', isa => 'Bool');
has loaded_group_conversations => (is => 'rw', isa => 'Bool');

has _is_ready => (is => 'rw', isa => 'Bool');

sub is_ready ($self) {
  return 1 if $self->_is_ready;

  # Stupid micro-opt
  if (
       $self->loaded_users
    && $self->loaded_channels
    && $self->loaded_dm_channels
    && $self->loaded_group_conversations
  ) {
    $self->_is_ready(1);
  }

  return $self->_is_ready;
}

sub load_users ($self) {
  $self->api_call('users.list', {
    presence => 0,
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content(charset => undef));
    my %users = map { $_->{id} => $_ } $res->{members}->@*;

    # See comment in _register_slack_rtm: here, we coerce our username to be
    # our ->own_name, because decode_slack_formatting converts @U12345 into
    # usernames. -- michael, 2019-06-04
    my $me = $users{ $self->own_id };
    $me->{name} = $self->own_name;

    $self->_set_users(\%users);
    $Logger->log("Users loaded");

    $self->loaded_users(1);
  });
}

sub load_channels ($self) {
  $self->api_call('conversations.list', {
    exclude_archived => 'true',
    types => 'public_channel',
    form_encoded => 1,
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content(charset => undef));
    $self->_set_channels({
      map { $_->{id}, $_ } $res->{channels}->@*
    });

    $Logger->log("Slack channels loaded");

    $self->loaded_channels(1);
  });
}

sub load_group_conversations ($self) {
  $self->api_call('conversations.list', {
    types => 'mpim,private_channel',
    form_encoded => 1,
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content(charset => undef));

    $self->_set_group_conversations({
      map { $_->{id},  $_ } $res->{channels}->@*
    });

    $Logger->log("Slack group conversations loaded");

    $self->loaded_group_conversations(1);
  });
}

sub group_conversation_name ($self, $id) {
  my $conversation;

  unless ($conversation = $self->group_conversations->{$id}) {
    # A new group chat materialized perhaps?
    $self->load_group_conversations->get();

    $conversation = $self->group_conversations->{$id};
  }

  return 'group' unless $conversation;

  return $conversation->{name} || 'group';
}


sub load_dm_channels ($self) {
  $self->api_call('conversations.list', {
    exclude_archived => 'true',
    types => 'im',
    form_encoded => 1,
  })->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content(charset => undef));

    $self->_set_dm_channels({
      map { $_->{user}, $_->{id} } $res->{ims}->@*
    });

    $Logger->log("Slack dm channels loaded");

    $self->loaded_dm_channels(1);
  });
}

1;
