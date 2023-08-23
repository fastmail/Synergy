use v5.32.0;
use warnings;
package Synergy::Channel::Discord;

use Moose;
use experimental qw(signatures);
use utf8;
use JSON::MaybeXS;
use Defined::KV;

use Synergy::External::Discord;
use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;
use Data::Dumper::Concise;

my $JSON = JSON->new->canonical;

with 'Synergy::Role::Channel';

has bot_token => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has discord => (
  is => 'ro',
  isa => 'Synergy::External::Discord',
  lazy => 1,
  default => sub ($self) {
    my $discord = Synergy::External::Discord->new(
      loop      => $self->loop,
      bot_token => $self->bot_token,
      name      => '_external_discord',
      on_event  => sub { $self->handle_discord_event(@_) },
    );

    $discord->register_with_hub($self->hub);
    return $discord;
  }
);

sub start ($self) {
  $self->discord->connect;
}

sub handle_discord_event ($self, $name, $event) {
  #warn Dumper ([$name, $event]);
  return unless $name eq 'MESSAGE_CREATE'; # XXX very stupid

  return if $event->{author}{bot};

  unless ($self->discord->is_ready) {
    $Logger->log("discord: ignoring message, we aren't ready yet");
    return;
  }

  my $synergy_event = $self->synergy_event_from_discord_event($event);
  $self->hub->handle_event($synergy_event);
}

sub synergy_event_from_discord_event ($self, $discord_event) {
  my $text = $self->decode_discord_formatting($discord_event->{content});

  my $from_user = $self->hub->user_directory->user_by_channel_and_address(
    $self->name, $discord_event->{author}{id},
  );

  my $from_username = $from_user
                    ? $from_user->username
                    : $self->discord->username($discord_event->{author}{id});

  my $was_targeted;
  my $me = $self->discord->own_name;
  my $new = $self->text_without_target_prefix($text, $me);
  if (defined $new) {
    $text = $new;
    $was_targeted = 1;
  }
  $was_targeted = 1 if $self->discord->is_dm_channel($discord_event->{channel_id});

  my $is_public = $self->discord->is_channel($discord_event->{channel_id});

  my $synergy_event = Synergy::Event->new({
    type                 => 'message',
    text                 => $text,
    was_targeted         => $was_targeted,
    is_public            => $is_public,
    from_channel         => $self,
    from_address         => $discord_event->{author}{id}, # XXX?
    defined_kv(from_user => $from_user),
    transport_data       => $discord_event,
    conversation_address => $discord_event->{channel_id}, # XXX?
  });
}

sub decode_discord_formatting ($self, $text) {
  # https://discordapp.com/developers/docs/reference#message-formatting

  # Username: <@80351110224678912>
  # User (nickname): <@!80351110224678912>
  $text =~ s/<\@!?(\d+)>/"@" . $self->discord->username($1)/ge;

  # Channel: <#103735883630395392>
  $text =~ s/<#(\d+)>/"#" . $self->discord->channelname($1)/ge;

  # XXX markdown formatting allegedly

  return $text;
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  Carp::cluck("send_message_to_user not implemented on Discord");
  return;
  # my $where = $self->discord->dm_channel_for_user($user, $self);
  # return $self->send_message($where, $text, $alts);
}

sub send_message ($self, $target, $text, $alts = {}) {
  my $f = $self->discord->send_message($target, $text, $alts);
  return $f;
}

sub describe_conversation ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $self->discord->users->{$event->from_address}{name};

  my $channel_id = $event->transport_data->{channel_id};
  if ($self->discord->is_channel($channel_id)) {
    return '#' . $self->discord->get_channel($channel_id)->{name};
  }

  if ($self->discord->is_dm_channel($channel_id)) {
    return '@' . $who;
  }

  return $self->discord->get_group_conversation($channel_id)->{name};
}

sub describe_event ($self, $event) {
  my $who = $event->from_user ? $event->from_user->username
                              : $self->discord->users->{$event->from_address}{name}; # XXX

  my $discord = $self->name;
  my $via   = qq{via Discord instance "$discord"};

  my $channel_id = $event->transport_data->{channel_id};

  if ($self->discord->is_channel($channel_id)) {
    my $channel_name = $self->discord->get_channel($channel_id)->{name};
    return qq{a message on #$channel_name from $who $via};
  }

  if ($self->discord->is_dm_channel($channel_id)) {
    return "a private message from $who $via";
  }

  return "an unknown discord communication from $who $via";
}

1;
