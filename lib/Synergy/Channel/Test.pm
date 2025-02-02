use v5.36.0;
package Synergy::Channel::Test;

use Moose;

use Future::AsyncAwait;
use IO::Async::Timer::Countdown;
use IO::Async::Timer::Periodic;

use Synergy::Event;

use namespace::autoclean;

with 'Synergy::Role::Channel';

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  my $to_address = $user->identity_for($self->name);

  unless ($to_address) {
    confess(
      sprintf "no address for user<%s> on channel<%s>",
        $user->username,
        $self->name,
    );
  }

  $self->send_message($to_address, $text, $alts);
}

sub send_message ($self, $address, $text, $alts = {}) {
  $self->record_message({ address => $address, text => $text });
  return Future->done;
}

sub describe_event { "(some test event)" }

sub describe_conversation ($self, $event) {
  return "test";
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

has default_from => (
  is  => 'ro',
  isa => 'Str',
  default => 'tester',
);

sub _inject_event ($self, $arg) {
  my $text = $arg->{text} // "This is a test, sent at " . localtime . ".";
  my $from_address = $arg->{from} // $self->default_from;

  my $had_prefix = 0;

  my $new = $self->text_without_target_prefix($text, $self->hub->name);

  if (defined $new) {
    $text = $new;
    $had_prefix = 1;
  }

  my $from_user = $self->hub->user_directory->user_by_channel_and_address($self->name, $from_address);

  my $event = Synergy::Event->new({
    type => 'message',
    text => $text,
    from_address => $from_address,
    ($from_user ? (from_user => $from_user) : ()),
    from_channel => $self,
    was_targeted => $had_prefix,
    conversation_address => 'public',
  });

  $self->hub->handle_event($event);
  return;
}

# when we queue an event, and the queue was empty, we should start it
#                                                  and become ! queue_exhausted
# when we try to dequeue and the queue is empty, we should become queue_exhausted
# new event type wait-for-reply

has todo => (
  isa       => 'ArrayRef',
  traits    => [ 'Array' ],
  default   => sub {  []  },
  handles   => {
    queue_todo    => 'push',
    dequeue_todo  => 'shift',
    queue_empty   => 'is_empty',
  },
);

after queue_todo => sub {
  my ($self) = @_;
  if ($self->is_queue_exhausted) {
    $self->_set_is_queue_exhausted(0);
    $self->do_next;
  }
};

before do_next => sub {
  my ($self) = @_;
  if ($self->queue_empty) {
    $self->_set_is_queue_exhausted(1);
  }
};

has is_queue_exhausted => (
  is => 'ro',
  writer    => '_set_is_queue_exhausted',
  lazy      => 1,
  init_arg  => undef,
  default   => sub ($self, @) { $self->queue_empty },
);

sub is_exhausted ($self) {
  return 0 unless $self->is_queue_exhausted;

  # If any http requests are in flight, our reactors are waiting and haven't
  # responded yet, so give them some more time
  return $self->hub->requests_in_flight ? 0 : 1;
}

sub _todo_to_notifier ($self, $todo) {
  my ($method, @rest) = @$todo;

  my $compiler = $self->can("_compile_$method");

  confess("bogus todo item: $method") unless $compiler;

  return $self->$compiler(@rest);
}

sub _compile_send ($self, $arg) {
  my $timer = IO::Async::Timer::Countdown->new(
    delay => 0,
    notifier_name => 'test-send-delayed',
    remove_on_expire => 1,
    on_expire => sub {
      my ($timer) = @_;
      $self->_inject_event($arg);
      $self->do_next;
    },
  );
  $timer->start;
  return $timer;
}

sub _compile_wait ($self, $arg) {
  my $timer = IO::Async::Timer::Countdown->new(
    delay => $arg->{seconds} // 0.05,
    notifier_name => 'test-wait',
    remove_on_expire => 1,
    on_expire => sub {
      my ($timer) = @_;
      $self->do_next;
    },
  );
  $timer->start;
  return $timer;
}

sub _compile_repeat ($self, $arg) {
  my $times = $arg->{times} // 5;
  my $sleep = $arg->{sleep} // 1;

  my $timer = IO::Async::Timer::Periodic->new(
    interval => $sleep,
    notifier_name => 'test-repeat',
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

sub do_next ($self) {
  my $next_todo = $self->dequeue_todo;
  return unless $next_todo;
  my $notifier = $self->_todo_to_notifier($next_todo);
  $self->loop->add($notifier);
  return;
}

async sub start ($self) {
  $self->do_next;
  return;
}

1;
