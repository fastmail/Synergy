use v5.24.0;
use warnings;
package Synergy::Channel::Slack;

use Moose;
use experimental qw(signatures);
use utf8;
use JSON::MaybeXS;

use Synergy::External::Slack;
use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;
use Data::Dumper::Concise;

my $JSON = JSON->new->canonical;

with 'Synergy::Role::Channel',
     'Synergy::Role::ProvidesUserStatus';

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has slack => (
  is => 'ro',
  isa => 'Synergy::External::Slack',
  lazy => 1,
  default => sub ($self) {
    my $slack = Synergy::External::Slack->new(
      loop    => $self->loop,
      api_key => $self->api_key,
      name    => '_external_slack',
    );

    $slack->register_with_hub($self->hub);
    return $slack;
  }
);

sub start ($self) {
  $self->slack->connect;

  $self->slack->client->{on_frame} = sub ($client, $frame) {
    return unless $frame;

    my $slack_event;
    unless (eval { $slack_event = $JSON->decode($frame) }) {
      $Logger->log("error decoding frame content: <$frame> <$@>");
      return;
    }

    if (! $slack_event->{type} && $slack_event->{reply_to}) {
      unless ($slack_event->{ok}) {
        $Logger->log([ "failed to send a response: %s", $slack_event ]);
      }

      return;
    }

    if ($slack_event->{type} eq 'hello') {
      $self->slack->setup;
      return;
    }

    if ($slack_event->{type} eq 'pong') {
      my $pong_timer = $self->slack->pong_timer;
      $pong_timer->stop;
      $self->loop->remove($pong_timer);
      $self->slack->clear_pong_timer;
      return;
    }

    # XXX dispatch these better
    return unless $slack_event->{type} eq 'message';

    unless ($self->slack->is_ready) {
      $Logger->log("ignoring message, we aren't ready yet");

      return;
    }

    if ($slack_event->{subtype}) {
      $Logger->log([
        "refusing to respond to message with subtype %s",
        $slack_event->{subtype},
      ]);
      return;
    }

    $self->handle_slack_message($slack_event);
  };
}

sub handle_slack_message ($self, $slack_event) {
  return if $slack_event->{bot_id};
  return if $self->slack->username($slack_event->{user}) eq 'synergy';

  # Ok, so we need to be able to look up the DM channels. If a bot replies
  # over the websocket connection, it doesn't have a bot id. So we need to
  # attempt to get the DM channel for this person. If it's a bot, slack will
  # say "screw you, buddy," in which case we'll return undef, which we'll
  # understand as "we will not ever respond to this person anyway. Thanks,
  # Slack. -- michael, 2018-03-15
  my $private_addr
    = $slack_event->{channel} =~ /^G/
    ? $slack_event->{channel}
    : $self->slack->dm_channel_for_address($slack_event->{user});

  return unless $private_addr;

  my $from_user = $self->hub->user_directory->user_by_channel_and_address(
    $self->name, $slack_event->{user}
  );

  my $from_username = $from_user
                    ? $from_user->username
                    : $self->slack->username($slack_event->{user});

  # decode text
  my $me = $self->slack->own_name;
  my $text = $self->decode_slack_formatting($slack_event->{text});

  my $was_targeted;

  if ($text =~ s/\A \@?($me)(?=\W):?\s*//ix) {
    $was_targeted = !! $1;
  }

  # Three kinds of channels, I think:
  # C - public channel
  # D - direct one-on-one message
  # G - group chat
  #
  # Only public channels public.
  # Everything is targeted if it's sent in direct message.
  my $is_public    = $slack_event->{channel} =~ /^C/;
  $was_targeted = 1 if $slack_event->{channel} =~ /^D/;

  my $event = Synergy::Event->new({
    type => 'message',
    text => $text,
    was_targeted => $was_targeted,
    is_public => $is_public,
    from_channel => $self,
    from_address => $slack_event->{user},
    ( $from_user ? ( from_user => $from_user ) : () ),
    transport_data => $slack_event,
    conversation_address => $slack_event->{channel},
  });

  $self->hub->handle_event($event);
}

sub decode_slack_formatting ($self, $text) {
  # Usernames: <@U123ABC>
  $text =~ s/<\@(U[A-Z0-9]+)>/"@" . $self->slack->username($1)/ge;

  # Channels: <#C123ABC|bottest>
  $text =~ s/<#[CD](?:[A-Z0-9]+)\|(.*?)>/#$1/g;

  # mailto: mailto:foo@bar.com|foo@bar.com (no surrounding brackets)
  $text =~ s/mailto:\S+?\|//g;

  # "helpful" url formatting:  <https://example.com|example.com>; keep what
  # user actually typed
  $text =~ s
    / < ([^>]+) >                             # Everything between <> pairs
    / my $tmp = $1; $tmp =~ s{^.*\|}{}g; $tmp # Kill all before |
    /xeg;

  # Anything with < and > around it is probably a URL at this point so remove
  # those
  $text =~ s/[<>]//g;

  $text =~ s/&lt;/</g;
  $text =~ s/&gt;/>/g;
  $text =~ s/&amp;/&/g;

  return $text;
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  my $where = $self->slack->dm_channel_for_user($user, $self);

  $self->send_message($where, $text, $alts);
}

sub send_message ($self, $target, $text, $alts = {}) {
  $text =~ s/&/&amp;/g;
  $text =~ s/</&lt;/g;
  $text =~ s/>/&gt;/g;

  $self->slack->send_message($target, $text, $alts);

  return;
}

sub _uri_from_event ($self, $event) {
  my $channel = $event->transport_data->{channel};

  return sprintf 'https://%s.slack.com/archives/%s/p%s',
    $self->slack->_team_data->{domain},
    $event->transport_data->{channel},
    $event->transport_data->{ts} =~ s/\.//r;
}

sub describe_event ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $self->slack->users->{$event->from_address}{name};

  my $channel_id = $event->transport_data->{channel};

  my $slack = $self->name;
  my $via   = qq{via Slack instance "$slack"};

  if ($channel_id =~ /^C/) {
    my $channel = $self->slack->channels->{$channel_id}{name};

    return qq{a message on #$channel from $who $via};
  } elsif ($channel_id =~ /^D/) {
    return "a private message from $who $via";
  } else {
    return "an unknown slack communication from $who $via";
  }
}

sub describe_conversation ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $self->slack->users->{$event->from_address}{name};

  my $slack_event = $event->transport_data;

  my $channel_id = $event->transport_data->{channel};

  if ($channel_id =~ /^C/) {
    my $channel = $self->slack->channels->{$channel_id}{name};
    return "#$channel";
  } elsif ($channel_id =~ /^D/) {
    return '@' . $who;
  } else {
    return $self->slack->group_conversation_name($channel_id);
  }
}

sub user_status_for ($self, $event, $user) {
  $self->slack->load_users->get;

  my $ident = $user->identities->{ $self->name };
  return unless $ident;

  return unless my $slack_user = $self->slack->users->{$ident};

  my $profile = $slack_user->{profile};
  return unless $profile->{status_emoji};

  my $reply = "Slack status: $profile->{status_emoji}";
  $reply .= " $profile->{status_text}" if length $profile->{status_text};

  return $reply;
}

1;
