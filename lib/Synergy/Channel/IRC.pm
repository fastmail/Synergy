use v5.24.0;
use warnings;
package Synergy::Channel::IRC;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS;

use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;

use Net::Async::IRC;

sub describe_event {}
sub describe_conversation {}

sub send_message_to_user { ...}

sub send_message ($self, $address, $text, $alts = {}) {
  $self->client->do_PRIVMSG(target => $address, text => $text);
  return Future->done; # ???
}

with 'Synergy::Role::Channel';

has host   => (is => 'ro', required => 1, isa => 'Str');
has client => (is => 'rw');

sub start ($channel) {
  my $nick = $channel->hub->name;

  my $client = Net::Async::IRC->new(
    on_message_text => sub {
      my ($irc, $message, $hints) = @_;
      $Logger->log([ "%s", { message => $message, hints => $hints } ]);

      return if $hints->{is_notice};

      my $text = $hints->{text};
      my $had_prefix = $text =~ s/\A\@?\Q$nick\E:?\s*//;

      my $event = Synergy::Event->new({
        type => 'message',
        text => $text,
        was_targeted  => $hints->{target_is_me} || $had_prefix,
        is_public     => 0, # XXX junk
        from_channel  => $channel,
        from_address  => $hints->{prefix_nick},
        transport_data => $hints, # XXX ???
        conversation_address => $hints->{prefix_nick},
      });

      $Logger->log("Event <<$text>> from <<$hints->{prefix_nick}>>");

      $channel->hub->handle_event($event);
    },
  );

  $channel->client($client);

  $channel->hub->loop->add($client);

  $client->login(
    host => $channel->host,
    nick => $nick,
    user => $nick,
    realname => $nick,
  )->then(sub {
    # This doesn't work yet.  I think it's because I don't understand how
    # send_message works properly. -- rjbs, 2019-06-12
    $client->send_message(join => { target_name => '#synergy' });
  })->then(sub {
    $Logger->log("connected"); Future->done
  })->get;

  return;
}

1;
