use v5.24.0;
package Synergy::Channel::Test;

use Moose;
use experimental qw(signatures);

use IO::Async::Timer::Periodic;

use Synergy::Event;
use Synergy::ReplyChannel;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has prefix => (
  is  => 'ro',
  isa => 'Str',
  default => q{synergy},
);

sub send_text ($self, $address, $text) {
  $self->record_message({ address => $address, text => $text });
}

sub describe_event { "no" }

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

sub _inject_event ($self, $arg) {
  my $text = $arg->{text} // "This is a test, sent at " . localtime . ".";
  my $from_address = $arg->{from_address} // 'tester';

  my $event = Synergy::Event->new({
    type => 'message',
    text => $self->prefix . ": " . $text,
    from_address => $from_address,
    from_channel => $self,
  });

  my $rch = Synergy::ReplyChannel->new({
    channel => $self,
    default_address => 'public',
    private_address => 'private',
  });

  $self->hub->handle_event($event, $rch);
  return;
}

has todo => (
  isa       => 'ArrayRef',
  traits    => [ 'Array' ],
  default   => sub {  []  },
  handles   => {
    queue_todo    => 'push',
    dequeue_todo  => 'shift',
  },
);

sub _todo_to_notifier ($self, $todo) {
  if ($todo->[0] eq 'message') {
    my $arg   = $todo->[1];
    my $timer = IO::Async::Timer::Countdown->new(
      delay => 0,
      on_expire => sub {
        my ($timer) = @_;
        $self->_inject_event($arg);
        $self->hub->loop->remove($timer);
        $self->do_next;
      },
    );
    $timer->start;
    return $timer;
  }

  if ($todo->[0] eq 'wait') {
    my $arg   = $todo->[1];
    my $timer = IO::Async::Timer::Countdown->new(
      delay => $arg->{seconds} // 1,
      on_expire => sub {
        my ($timer) = @_;
        $self->hub->loop->remove($timer);
        $self->do_next;
      },
    );
    $timer->start;
    return $timer;
  }

  if ($todo->[0] eq 'repeat') {
    my $arg   = $todo->[1];
    my $times = $arg->{times} // 5;
    my $sleep = $arg->{sleep} // 1;

    my $timer = IO::Async::Timer::Periodic->new(
      interval => $sleep,
      on_tick  => sub {
        my ($timer) = @_;

        state $ticks = 0;

        $self->_inject_event($arg);

        if (++$ticks == $times) {
          $self->hub->loop->remove($timer);
          $self->do_next;
        }
      }
    );

    $timer->start;
    return $timer;
  }

  confess("bogus todo item: $todo->[0]");
}

sub do_next ($self) {
  my $next_todo = $self->dequeue_todo;
  return unless $next_todo;
  my $notifier = $self->_todo_to_notifier($next_todo);
  $self->loop->add($notifier);
  return;
}

sub start ($self) {
  $self->do_next;
}

1;
