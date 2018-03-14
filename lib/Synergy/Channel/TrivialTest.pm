use v5.24.0;
package Synergy::Channel::TrivialTest;

use Moose;
use experimental qw(signatures);

use IO::Async::Timer::Periodic;
use Synergy::ReplyChannel::Callback;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has interval => (
  is  => 'ro',
  isa => 'Int',
  default => 3,
);

has debug_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  default => sub {  sub {}  }
);

has replies => (
  isa => 'ArrayRef',
  default  => sub {  []  },
  init_arg => undef,
  reader   => '_reply_reference',
  traits   => [ 'Array' ],
  handles  => {
    reply_count   => 'count',
    record_reply  => 'push',
    clear_replies => 'clear',
    replies       => 'elements',
  },
);

sub start ($self) {
  my $rch = do {
    my $weak_self = $self;
    Scalar::Util::weaken($weak_self);
    Synergy::ReplyChannel::Callback->new({
      to_reply => sub ($channel, $text) {
        $weak_self->record_reply($text);
        $weak_self->debug_callback->("Sent reply: $text");
      }
    });
  };

  my $timer = IO::Async::Timer::Periodic->new(
    interval => $self->interval,
    on_tick  => sub {
      state $reply_count = 0;
      my $replies = $self->reply_count;

      my $debug = $self->debug_callback;
      $debug->("We saw $replies since last time...");

      $reply_count++;

      my $event = Synergy::Event->new({
        type => 'message',
        text => "It's " . localtime . ", do you know where you are?",
        from => "tester",
      });

      $self->hub->handle_event($event, $rch);
    }
  );

  $self->loop->add($timer);
  $timer->start;
}

1;
