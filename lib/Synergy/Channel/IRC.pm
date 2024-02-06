use v5.24.0;
use warnings;
package Synergy::Channel::IRC;

use Moose;
use experimental qw(signatures);

use Future::AsyncAwait;

use JSON::MaybeXS;

use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;

use Defined::KV;
use Net::Async::IRC;

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
      $Logger->log([ "%s", { message => $message, hints => $hints } ]);

      return if $hints->{is_notice};

      my $me    = $channel->hub->name; # Should be IRC client name, actually.
      my $text  = Encode::decode('UTF-8', $hints->{text});
      my $was_targeted = 0;

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
        is_public     => !! ($hints->{target_type} eq 'channel'),
        from_channel  => $channel,
        from_address  => $hints->{prefix_nick},
        defined_kv(from_user => $from_user),
        transport_data => $hints, # XXX ???
        conversation_address => $hints->{target_name},
      });

      $Logger->log("Event <<$text>> from <<$hints->{prefix_nick}>>");

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

  $Logger->log("connected to server");

  await $client->send_message(JOIN => (undef) => "#synergy-bot");

  $Logger->log("joined channel");

  return;
}

1;
