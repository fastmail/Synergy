use v5.36.0;
package Synergy::Channel::IRC;

use Moose;

use Future::AsyncAwait;

use JSON::MaybeXS;

use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;

use Defined::KV;
use Net::Async::IRC;

has irc_channels => (
  isa => 'ArrayRef[Str]',
  traits  => [ 'Array' ],
  handles => { irc_channels => 'elements' },
  required => 1,
);

before start => sub ($self) {
  # This really should be done with a MooseX::Type, probably, but for now this
  # is faster and simpler.
  my @irc_channels = $self->irc_channels;
  unless (@irc_channels) {
    $Logger->log_fatal([
      "channel %s: empty irc_channels specified",
      $self->name,
    ]);
  }

  my @bad = grep {; ! /\A[#&][-_0-9a-z]*\z/ } @irc_channels;
  if (@bad) {
    $Logger->log_fatal([
      "channel %s: invalid irc_channels specified: %s",
      $self->name,
      \@bad,
    ]);
  }
};

sub describe_event {}
sub describe_conversation {}

async sub send_message_to_user ($self, $user, $text, $alts = {}) {
  await $self->send_message(
    $user->identity_for($self->name),
    $alts->{irc} // $text,
  );
}

sub send_message ($self, $address, $text, $alts = {}) {
  my @lines = split /\n/, $text;

  my $now = Future->done; # The Future is Now!

  for my $line (@lines) {
    next unless length $line; # I'm not sure this is what I want to do.
    $line = Encode::encode('utf-8', $line);
    my $now = $now->retain->then(sub {
      $self->client->do_PRIVMSG(target => $address, text => $line);
    });
  }

  return $now->else(sub {
    my (@error) = @_;
    $Logger->log([ "IRC: error sending response: %s", \@error ]);
    return Future->done;
  });
}

with 'Synergy::Role::Channel';

has host   => (is => 'ro', required => 1, isa => 'Str');
has client => (is => 'rw');

async sub start ($channel) {
  my $nick = $channel->hub->name;

  my $client = Net::Async::IRC->new(
    on_message_text => sub {
      my ($irc, $message, $hints) = @_;

      $Logger->log_debug([
        "%s channel: IRC message: %s",
        $channel->name,
        { message => $message, hints => $hints }
      ]);

      return if $hints->{is_notice};

      my $me    = $channel->hub->name; # Should be IRC client name, actually.
      my $text  = Encode::decode('UTF-8', $hints->{text});
      my $was_targeted = $hints->{target_type} eq 'user' ? 1 : 0;

      my $new = $channel->text_without_target_prefix($text, $me);
      if (defined $new) {
        $text = $new;
        $was_targeted = 1;
      }

      my $from_user = $channel->hub->user_directory->user_by_channel_and_address(
        $channel->name,
        $hints->{prefix_nick},
      );

      my $event = Synergy::Event->new({
        type => 'message',
        text => $text,
        was_targeted  => $was_targeted,
        is_public     => ($hints->{target_type} eq 'channel' ? 1 : 0),
        from_channel  => $channel,
        from_address  => $hints->{prefix_nick},
        defined_kv(from_user => $from_user),
        transport_data => $hints, # XXX ???
        conversation_address => (
          $hints->{target_type} eq 'channel'
            ? $hints->{target_name}
            : $hints->{prefix_nick}
        )
      });

      $channel->hub->handle_event($event);
    },
  );

  $channel->client($client);

  $channel->hub->loop->add($client);

  await $client->login(
    host => $channel->host,
    nick => $nick,
    user => $nick,
    realname => $nick,
  );

  $Logger->log([ "channel %s: connected to IRC server", $channel->name ]);

  for my $channel_name ($channel->irc_channels) {
    await $client->send_message(JOIN => (undef) => "#synergy-bot");
    $Logger->log([ "channel %s: joined %s", $channel->name, $channel_name ]);
  }

  return;
}

1;
