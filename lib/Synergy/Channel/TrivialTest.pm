use v5.24.0;
package Synergy::Channel::TrivialTest;

use Moose;
use experimental qw(signatures);

use IO::Async::Timer::Periodic;

use Synergy::Event;
use Synergy::ReplyChannel;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has interval => (
  is  => 'ro',
  isa => 'Int',
  default => 3,
);

has prefix => (
  is  => 'ro',
  isa => 'Str',
  default => q{synergy},
);

has debug_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  default => sub {  sub {}  }
);

sub send_text ($self, $address, $text) {
  $self->record_message({ address => $address, text => $text });
}

has sent_messages => (
  isa => 'ArrayRef',
  default  => sub {  []  },
  init_arg => undef,
  reader   => '_reply_reference',
  traits   => [ 'Array' ],
  handles  => {
    sent_message_count  => 'count',
    record_message      => 'push',
    clear_messages      => 'clear',
    sent_messages       => 'elements',
  },
);

sub start ($self) {
  my $timer = IO::Async::Timer::Periodic->new(
    interval => $self->interval,
    on_tick  => sub {
      state $reply_count = 0;
      my $replies = $self->sent_message_count;

      my $debug = $self->debug_callback;
      $debug->("We saw $replies since last time...");

      $reply_count++;

      my $event = Synergy::Event->new({
        type => 'message',
        text => $self->prefix . ": It's " . localtime . ", do you know where you are?",
        from_address => "tester",
        from_channel => $self,
      });

      my $rch = Synergy::ReplyChannel->new({
        channel => $self,
        default_address => 'public',
        private_address => 'private',
      });

      $self->hub->handle_event($event, $rch);
    }
  );

  $self->loop->add($timer);
  $timer->start;
}

1;
