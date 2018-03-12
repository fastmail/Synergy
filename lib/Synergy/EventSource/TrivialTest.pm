use v5.24.0;
package Synergy::EventSource::TrivialTest;

use Moose;
use experimental qw(signatures);

use IO::Async::Timer::Periodic;

use namespace::autoclean;

with 'Synergy::EventSource';

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

sub BUILD ($self, @) {
  my $timer = IO::Async::Timer::Periodic->new(
    interval => $self->interval,
    on_tick  => sub {
      my $rch = $self->rch;
      my $replies = $rch->reply_count;

      my $debug = $self->debug_callback;
      $debug->("We saw $replies since last time...");

      for my $reply ($rch->replies) {
        $debug->( sprintf '%8i %s', @$reply );
      }
      $rch->clear_replies;

      my $event = Synergy::Event->new({
        type => 'message',
        text => "It's " . localtime . ", do you know where you are?",
        from => "tester",
      });

      $self->eventhandler->handle_event($event, $rch);
    }
  );

  $self->loop->add($timer);
  $timer->start;
}

1;
