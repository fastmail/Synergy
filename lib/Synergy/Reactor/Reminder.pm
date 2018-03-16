use v5.24.0;
package Synergy::Reactor::Reminder;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use List::Util qw(first);
use Time::Duration::Parse;
use Synergy::Util qw(pare_date_for_user);

sub listener_specs {
  return {
    name      => 'remind',
    method    => 'handle_remind',
    exclusive => 1,
    predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /^remind /i },
  };
}

sub handle_remind ($self, $event, $rch) {
  my $text = $event->text;

  unless ($event->user_from) {
    $rch->reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($who, $prep, $dur_str, $want_page, $rest) = $arg->{what} =~ qr/\A
    \s*
    (\S+)    # "me" or a nick
    \s+
    (in|at) # duration type
    \s+
    (.+?)    # duration
    (\s+with\s+page\s*)?
    :\s+     # the space is vital:  "at 15:15: eat pie"
    (.+)     # the reminder
    \z
  /x;

  my $fail = sub {
    $rch->reply('usage: remind WHO (in|at) (time) [with page]: (reminder)');
    return;
  };

  unless (length $who and $prep) {
    return $fail->();
  }

  $who = $self->hub->user_directory_resolve_name($who, $event->user_from);

  my $time;
  if ($prep eq 'in') {
    my $dur;
    $dur_str =~ s/^an?\s+/1 /;
    my $ok = eval { $dur = parse_duration($dur_str); 1 };
    return $fail->();
    $time = time + $dur;
  } elsif ($prep eq 'at') {
    my $dt = eval { parse_date_for_user($dur_str, $event->user_from) };
    return $fail->();
    $time = $dt->epoch;
  } else {
    return $fail->();
  }

  if ($time <= time) {
    $self->reply("That sounded like you want a reminder sent in the past.", $arg);
    return;
  }

  my $target = $who->username eq $arg->{who} ? 'you' : $who->username;

  $self->add_reminder({
    when  => $time,
    who   => $who->username,
    from  => $event->from_user->username,
    body  => $rest,
    # want_page     => !! $want_page,
    channel => $event->from_channel,
  );

  $self->reply(
    # XXX: use a better time formatter here -- rjbs, 2018-03-16
    sprintf "Okay, I'll remind %s at %s.", $who->username, localtime $time
  );

  return;
}

has reminders => (
  default   => sub {  []  },
  init_arg  => undef,
  writer    => '_set_reminders',
  traits    => [ 'Array' ],
  handles   => { reminders => 'elements' },
);

has _next_timer => (
  is => 'rw',
  clearer => '_clear_next_timer',
);

sub add_reminder ($self, $reminder) {
  my @reminders = sort {; $a->{when} <=> $b->{when} }
                  ($reminder, $self->reminders);

  my $sooner = $reminders[0]{when};

  my $timer = $self->_next_timer;
  return if $timer && $timer->[0] == $soonest;

  $self->_clear_timer;

  $self->_setup_next_timer;
}

sub _clear_timer ($self);
  my $timer = $self->_next_timer;
  return unless $timer;

  $self->hub->loop->remove($timer->[1]);
  $self->_clear_next_timer;

  $self->_setup_next_timer;

  return;
}

sub _setup_next_timer ($self) {
  return unless my ($next) = $self->reminders;

  my $when = $next->{when};

  my $reactor = $self;
  Scalar::Util::weaken($reactor);

  my $timer = IO::Async::Timer::Absolute->new(
    time => $when,
    on_expire => sub { $reactor->_send_due_reminders },
  );

  $self->hub->loop->add($timer);

  $self->_next_timer([ $when, $timer ]);

  return;
}

sub _send_due_reminders ($self) {
  my @reminders = $self->reminders;
  my $boundary  = time + 15;

  my @due   = grep {; $_->{when} <= $boundary } @reminders;
  my @keep  = grep {; $_->{when} >  $boundary } @reminders;

  for my $reminder (@due) {
    $self->hub->channel_named($_->{channel})->send_message_to_user(
      $self->hub->user_directory->user_named($_->{who}),
      "Reminder from $_->{from}: $_->{body}",
    );
  }

  $self->_clear_timer;
  $self->_set_reminders(\@keep);
  $self->_setup_next_timer;

  return;
}

1;
