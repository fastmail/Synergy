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

sub start ($channel) {
  my $nick = $channel->hub->name;

  my $client = Net::Async::IRC->new(
    on_message_text => sub {
      my ($irc, $message, $hints) = @_;
      $Logger->log([ "%s", { message => $message, hints => $hints } ]);

      return if $hints->{is_notice};

      my $text = $hints->{text};
      my $had_prefix = $text =~ s/\A\@?\Q$nick\E:?\s*//i;

      my $event = Synergy::Event->new({
        type => 'message',
        text => $text,
        was_targeted  => $hints->{target_is_me} || $had_prefix,
        is_public     => !! ($hints->{target_type} eq 'channel'),
        from_channel  => $channel,
        from_address  => $hints->{prefix_nick},
        transport_data => $hints, # XXX ???
        conversation_address => $hints->{target_name},
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
    $client->send_message(JOIN => { target_name => '#synergy' });
  })->then(sub {
    $Logger->log("connected"); Future->done
  })->get;

  return;
}

1;
