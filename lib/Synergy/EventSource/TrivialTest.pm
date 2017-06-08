use v5.24.0;
package Synergy::EventSource::TrivialTest;

use Moose;
use experimental qw(signatures);

use IO::Async::Timer::Periodic;

use namespace::clean;

has loop         => (is => 'ro', required => 1);
has eventhandler => (is => 'ro', required => 1);

has rch => (
  is => 'ro',
  default => sub {
    Synergy::ReplyChannel::Test->new;
  },
);

sub BUILD ($self, @) {
  my $timer = IO::Async::Timer::Periodic->new(
    interval => 3,
    on_tick  => sub {
      my $rch = $self->rch;
      my $replies = $rch->reply_count;
      warn "We saw $replies since last time...\n";
      for my $reply ($rch->replies) {
        say sprintf '%8i %s', @$reply;
      }
      $rch->clear_replies;

      my $event = Synergy::Event->new({
        type => 'message',
        text => "It's " . localtime . ", do you know where you are?",
      });

      $self->eventhandler->handle_event($event, $rch);
    }
  );

  $self->loop->add($timer);
  $timer->start;
}

1;
