use v5.32.0;
use warnings;
package Synergy::External::Slack;

use Moose;
use experimental qw(signatures);
use namespace::autoclean;
use utf8;

use Future::AsyncAwait;
use JSON::MaybeXS qw(decode_json encode_json);
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::Async::WebSocket::Client;
use Data::Dumper::Concise;
use Defined::KV;

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
  predicate => '_has_users',
);

has channels => (
  is => 'ro',
  isa => 'HashRef',
  writer => '_set_channels',
  predicate => '_has_channels',
);

has group_conversations => (
  is => 'ro',
  isa => 'HashRef',
  writer => '_set_group_conversations',
  predicate => '_has_group_conversations',
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
  predicate => '_has_dm_channels',
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

async sub connect ($self) {
  $self->connected(0);

  my $res = await $self->hub->http_client->GET(
    "https://slack.com/api/rtm.connect?token=" . $self->api_key
  );

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

  return;
}

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

    # XXX Blocking here is crappy.  This is another place where we've pushed
    # the "where is it async" around under the carpet, but haven't fully ironed
    # out the lump yet. -- rjbs, 2023-10-10
    $self->client->close;
    $self->connect->get;

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
      return $self->send_reaction($r->{reaction}, {
        channel   => $e->transport_data->{channel},
        timestamp => $e->transport_data->{ts},
      });
    }
  }

  return $self->_send_rich_text($channel, $alts->{slack}, $alts)
    if $alts->{slack};

  return $self->_send_plain_text($channel, $text);
}

sub send_reaction ($self, $reaction, $arg) {
  my $remove = $reaction =~ s/^-//;

  my $http_future = $self->api_call(
    ($remove ? 'reactions.remove' : 'reactions.add'),
    {
      name      => $reaction,
      channel   => $arg->{channel},
      timestamp => $arg->{timestamp},
    }
  );

  my $f = $self->loop->new_future;

  $http_future->on_done(sub ($http_res) {
    my $res = decode_json($http_res->decoded_content);
    return $f->done({
      type => 'slack',
      transport_data => $res
    });
  });

  return $f;
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

sub _send_rich_text ($self, $channel, $rich, $alts) {
  my %extra_args = $alts->{slack_postmessage_args}
                 ? $alts->{slack_postmessage_args}->%*
                 : ();

  my $http_future = $self->api_call('chat.postMessage', {
    %extra_args,

    (ref $rich ? (%$rich) : (text => $rich)),
    channel => $channel,
    as_user => \1,
  });

  $http_future->on_fail(sub (@rest) {
    $Logger->log([ "error with chat.postMessage: %s", \@rest ]);
  });

  my $f = $self->loop->new_future;
  $http_future->on_done(sub ($http_res) {
    my $payload = eval {
      decode_json($http_res->decoded_content(charset => undef));
    };

    unless ($payload) {
      my $error = $@;

      $Logger->log([
        "chat.postMessage did not return JSON in %s reply",
        $http_res->code,
      ]);

      die $error;
    }

    $f->done({
      type => 'slack',
      transport_data => $payload,
    });
  });

  return $f;
}

async sub send_file ($self, $channel, $filename, $content, $title = undef) {
  # Sending a file is a three step process:
  # 1. GET an upload url (files.getUploadURLExternal)
  # 2. POST the file to the upload url ($uploadurl)
  # 3. POST to complete the upload (files.completeUploadExternal)

  # step 1:
  my $u = URI->new($self->_api_url('files.getUploadURLExternal'));
  $u->query_param(filename => $filename);
  $u->query_param(length => (length $content));

  my $get_upload_res = await $self->hub->http_client->GET(
    $u,
    content_type => 'application/x-www-form-urlencoded',
    headers => [
      $self->_api_auth_header,
    ],
  );

  my $json = decode_json($get_upload_res->content);
  die "Could get upload url to send file to slack: " . $json->{error}
    unless $json->{ok};

  my $post_content_res = await $self->hub->http_client->POST(
    $json->{upload_url},
    $content,
    content_type => 'application/x-www-form-urlencoded',
  );

  die "Could not send file to slack: " . $post_content_res->content
    unless $post_content_res->is_success;

  # step 3:
  my $json_args = encode_json({
    channel_id => $channel,
    files      => [{
      id => $json->{file_id},
      defined_kv(title => $title),
    }],
  });

  # The docs say application/x-www-form-urlencoded
  # OR application/json but the former does not work
  my $post_complete_res = await $self->hub->http_client->POST(
    URI->new($self->_api_url('files.completeUploadExternal')),
    $json_args,
    content_type => 'application/json; charset=utf-8',
    headers => [
      $self->_api_auth_header,
    ],
  );

  $json = decode_json($post_complete_res->content);
  die "Could not finalise upload file to slack: " . $json->{error}
    unless $json->{ok};

  return;
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

sub username ($self, $id) {
  my $users = $self->users;

  # This stinks!  Sometimes we try to decode an event before we have finished
  # initializing the users structure.  This really shouldn't happen, but we
  # recently flew very close to the sun.  In a perfect world, we'd make it
  # possible to sequence on this, but it isn't.  So we have this silly
  # fallback… -- rjbs, 2021-12-21
  return $users->{$id}->{name} if $users;
  return "<unknown user $id>";
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

sub readiness ($self) {
  Future->needs_all(
    map {; my $m = "load_$_"; $self->$m }
      qw( users channels group_conversations dm_channels )
  );
}

async sub load_users ($self) {
  return if $self->_has_users;

  my $http_res = await $self->api_call('users.list', {
    presence => 0,
  });

  my $res = decode_json($http_res->decoded_content(charset => undef));
  my %users = map { $_->{id} => $_ } $res->{members}->@*;

  # See comment in _register_slack_rtm: here, we coerce our username to be
  # our ->own_name, because decode_slack_formatting converts @U12345 into
  # usernames. -- michael, 2019-06-04
  my $me = $users{ $self->own_id };
  $me->{name} = $self->own_name;

  $self->_set_users(\%users);
  $Logger->log("Slack users loaded");
  return;
}

async sub load_channels ($self) {
  return if $self->_has_channels;

  my $http_res = await $self->api_call('conversations.list', {
    exclude_archived => 'true',
    types => 'public_channel',
    limit => 200,
    form_encoded => 1,
  });

  my $res = decode_json($http_res->decoded_content(charset => undef));
  $self->_set_channels({
    map { $_->{id}, $_ } $res->{channels}->@*
  });

  $Logger->log("Slack channels loaded");

  return;
}

async sub load_group_conversations ($self) {
  return if $self->_has_group_conversations;

  my $http_res = await $self->api_call('conversations.list', {
    types => 'mpim,private_channel',
    form_encoded => 1,
  });

  my $res = decode_json($http_res->decoded_content(charset => undef));

  $self->_set_group_conversations({
    map { $_->{id},  $_ } $res->{channels}->@*
  });

  $Logger->log("Slack group conversations loaded");

  return;
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

async sub load_dm_channels ($self) {
  return if $self->_has_dm_channels;

  my $http_res = await $self->api_call('conversations.list', {
    exclude_archived => 'true',
    types => 'im',
    form_encoded => 1,
  });

  my $res = decode_json($http_res->decoded_content(charset => undef));

  $self->_set_dm_channels({
    map { $_->{user}, $_->{id} } $res->{ims}->@*
  });

  $Logger->log("Slack dm channels loaded");

  return;
}

1;
