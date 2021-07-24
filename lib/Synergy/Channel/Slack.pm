use v5.24.0;
use warnings;
package Synergy::Channel::Slack;

use Moose;
use experimental qw(signatures);
use utf8;
use JSON::MaybeXS;
use IO::Async::Timer::Periodic;

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

has privileged_api_key => (
  is => 'ro',
  lazy => 1,
  default => sub { $_[0]->api_key },
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
      privileged_api_key => $self->privileged_api_key,
    );

    $slack->register_with_hub($self->hub);
    return $slack;
  }
);

# {
#   user_message_ts => {
#     channel   => $channel,
#     was_targeted => $bool,
#     replies => [
#       {
#         was_error => bool,
#         reply_ts  => $our_ts,
#       }
#     ]
#   }
# }
has our_replies => (
  is      => 'ro',
  isa     => 'HashRef',
  traits  => ['Hash'],
  lazy    => 1,
  default => sub { {} },
  handles => {
    replies_for         => 'get',
    set_reply           => 'set',
    reply_timestamps    => 'keys',
    delete_reply_record => 'delete',
  },
);

sub add_reply ($self, $event, $reply_data) {
  my ($channel, $ts) = $event->transport_data->@{qw( channel ts )};
  return unless $ts;

  my $existing = $self->replies_for($ts);

  if (! $existing) {
    $existing = {
      channel      => $channel,
      was_targeted => $event->was_targeted,
      replies      => [],
    };

    $self->set_reply($ts, $existing);
  }

  push $existing->{replies}->@*, $reply_data;
}

# Clean out our state so we don't respond to edits older than 2m
has reply_reaper => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return IO::Async::Timer::Periodic->new(
      interval => 35,
      on_tick  => sub {
        my $then = time - 120;

        for my $ts ($self->reply_timestamps) {
          $self->delete_reply_record($ts) if $ts lt $then;
        }
      },
    );
  }
);

my %allowable_subtypes = map {; $_ => 1 } qw(
  me_message
);

sub start ($self) {
  $self->slack->connect;
  $self->loop->add($self->reply_reaper->start);

  $self->slack->client->{on_frame} = sub ($client, $frame) {
    return unless $frame;

    my $slack_event;
    unless (eval { $slack_event = $JSON->decode($frame) }) {
      $Logger->log("error decoding frame content: <$frame> <$@>");
      return;
    }

    # This is silly, but Websocket::Client's on_frame isn't a stack of
    # subs to call, it's only a single sub. -- michael, 2019-02-03
    $self->slack->handle_frame($slack_event);

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

    # XXX dispatch these better
    return unless $slack_event->{type} eq 'message';

    unless ($self->slack->is_ready) {
      $Logger->log("ignoring message, we aren't ready yet");
      return;
    }

    my $subtype = $slack_event->{subtype};

    if ($subtype && $subtype eq 'message_changed') {
      $self->maybe_respond_to_edit($slack_event);
      return;
    }

    if ($subtype && $subtype eq 'message_deleted') {
      $self->maybe_delete_reply($slack_event);
      return;
    }

    if ($subtype && ! $allowable_subtypes{$subtype}) {
      $Logger->log([
        "refusing to respond to message with subtype %s",
        $slack_event->{subtype},
      ]);
      return;
    }

    return if $slack_event->{bot_id};
    return if $self->slack->username($slack_event->{user}) eq 'synergy';

    my $event = $self->synergy_event_from_slack_event($slack_event);
    unless ($event) {
      $Logger->log([
        "couldn't convert a %s/%s message to channel %s, dropping it",
        $slack_event->{type},
        ($subtype // '[none]'),
        $slack_event->{channel},
      ]);
      return;
    }

    $self->hub->handle_event($event);
  };
}

sub synergy_event_from_slack_event ($self, $slack_event, $type = 'message') {
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
    type => $type,
    text => $text,
    was_targeted => $was_targeted,
    is_public => $is_public,
    from_channel => $self,
    from_address => $slack_event->{user},
    ( $from_user ? ( from_user => $from_user ) : () ),
    transport_data => $slack_event,
    conversation_address => $slack_event->{channel},
  });

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

  # kill zero-width-space so copy/paste works ok
  $text =~ s/\x{0200B}//g;

  $text =~ s/&lt;/</g;
  $text =~ s/&gt;/>/g;
  $text =~ s/&amp;/&/g;

  # Weirdly, desktop Slack kills leading/trailing spaces, but on mobile it
  # will happily send them.
  $text =~ s/^\s*|\s$//g;

  return $text;
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  my $where = $self->slack->dm_channel_for_user($user, $self);
  return $self->send_message($where, $text, $alts);
}

sub send_message ($self, $target, $text, $alts = {}) {
  $text =~ s/&/&amp;/g;
  $text =~ s/</&lt;/g;
  $text =~ s/>/&gt;/g;

  my $f = $self->slack->send_message($target, $text, $alts);
  return $f;
}

# TODO: don't send ephemeral messages to the same user, in the same channel,
# about the same thing. That requires more state than I'm willing to write
# right now, because that state should properly go in the reactors. But since
# this returns a future, reactors can implement that in the future if needed.
# -- michael, 2019-02-05
sub send_ephemeral_message ($self, $channel, $user, $text) {
  $text =~ s/&/&amp;/g;
  $text =~ s/</&lt;/g;
  $text =~ s/>/&gt;/g;

  my $ret_future = $self->loop->new_future;
  $self->slack->api_call('chat.postEphemeral', {
    text => $text,
    channel => $channel,
    user => $user,
    as_user => \1,
  })->on_done(sub ($http_res) {
    my $json = $JSON->decode($http_res->decoded_content);
    $ret_future->done($json);
  });

  return $ret_future;
}

sub note_reply ($self, $event, $future, $args = {}) {
  my $ts = $event->transport_data->{ts};
  return unless $ts;

  $future->on_done(sub ($data) {
    unless ($data->{type} eq 'slack') {
      $Logger->log([
        "got bizarre type back from slack future: %s",
        $data
      ]);
      return;
    }

    # Slack reactions results just have { ok: true }
    # -- michael, 2019-02-05
    return unless $data->{transport_data}{ts};

    $self->add_reply($event, {
      reply_ts  => $data->{transport_data}{ts},
      was_error => $args->{was_error} ? 1 : 0,
    });
  });
}

sub maybe_respond_to_edit ($self, $slack_event) {
  my $orig_ts = $slack_event->{message}{ts};
  my $reply_data = $self->replies_for($orig_ts);

  unless ($reply_data) {
    $Logger->log("ignoring edit of a message we didn't respond to");
    return;
  }

  $Logger->log([ "found original messages for edit: %s", $reply_data ]);

  unless ($slack_event->{channel} eq $reply_data->{channel}) {
    $Logger->log("ignoring edit whose channel doesn't match reply channel");
    return;
  }

  if ($slack_event->{message}{attachments}
    && ! $slack_event->{previous_message}{attachments}) {
    $Logger->log("ignoring edit of message that added attachments");
    return;
  }

  $Logger->log([ 'will attempt to handle edit event: %s', $slack_event ]);

  # Massage the slack event a bit, then reinject it.
  my $message = $slack_event->{message};
  $message->{channel} = $slack_event->{channel};
  $message->{event_ts} = $slack_event->{event_ts};

  # Find the error-causing part(s). If there weren't any, we can't do
  # anything.
  my @error_ts = map  {; $_->{reply_ts} }
                 grep {; $_->{was_error} }
                 $reply_data->{replies}->@*;

  unless (@error_ts) {
    return unless $reply_data->{was_targeted};

    $Logger->log([ 'unable to respond to edit of non-error-causing event' ]);

    my $event = $self->synergy_event_from_slack_event($message, 'edit');
    $event->ephemeral_reply(
      "I can only respond to edits of messages that caused errors, sorry."
    );
    return;
  }

  $self->delete_reply($orig_ts, $_) for @error_ts;

  my $event = $self->synergy_event_from_slack_event($message, 'message');
  $self->hub->handle_event($event);
}

sub delete_reply ($self, $orig_ts, $reply_ts) {
  my $reply_data = $self->replies_for($orig_ts);
  return unless $reply_data;

  $self->slack->api_call('chat.delete', {
    channel => $reply_data->{channel},
    ts      => $reply_ts,
  });

  # Do the new bookkeeping
  my @new = grep {; $_->{reply_ts} ne $reply_ts }
            $reply_data->{replies}->@*;

  if (@new) {
    $reply_data->{replies} = \@new;
  } else {
    $self->delete_reply_record($orig_ts);
  }
}

sub maybe_delete_reply ($self, $slack_event) {
  my $orig_ts = $slack_event->{previous_message}{ts};
  return unless $orig_ts;
  my $reply_data = $self->replies_for($orig_ts);

  unless ($reply_data) {
    $Logger->log("ignoring deletion of a message we didn't respond to");
    return;
  }

  unless ($slack_event->{channel} eq $reply_data->{channel}) {
    $Logger->log("ignoring deletion whose channel doesn't match reply channel");
    return;
  }

  my @error_ts = map  {; $_->{reply_ts} }
                 grep {; $_->{was_error} }
                 $reply_data->{replies}->@*;

  unless (@error_ts) {
    $Logger->log("ignoring deletion of a message that didn't result in error");
    return;
  }

  $self->delete_reply($orig_ts, $_) for @error_ts;
}

sub send_file_to_user ($self, $user, $filename, $content) {
  my $where = $self->slack->dm_channel_for_user($user, $self);
  return $self->slack->send_file($where, $filename, $content);
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

sub describe_event_concise ($self, $event) {
  my $slack = $self->name;
  my $desc = $self->describe_conversation($event);
  return qq{$slack message in $desc};
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

  my $ident = $user->identity_for($self->name);
  return unless $ident;

  return unless my $slack_user = $self->slack->users->{$ident};

  my $profile = $slack_user->{profile};
  return unless $profile->{status_emoji};

  my $reply = "Slack status: $profile->{status_emoji}";
  $reply .= " $profile->{status_text}" if length $profile->{status_text};

  return $reply;
}

1;
