use v5.24.0;
package Synergy::Reactor::Reminder;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use IO::Async::Timer::Absolute;
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

has page_channel_name => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_page_channel_name',
);

sub state ($self) {
  return {
    reminders => [ $self->reminders ],
  };
}

sub start ($self) {
  if ($self->has_page_channel_name) {
    my $name    = $self->page_channel_name;
    my $channel = $self->hub->channel_named($name);
    confess("no channel named $name, cowardly giving up")
      unless $channel;
  }

  my $state = $self->fetch_state;
  if ($state && $state->{reminders}) {
    $self->add_reminder($_) for $state->{reminders}->@*;
  }

  return;
}

sub handle_remind ($self, $event, $rch) {
  my $text = $event->text;

  # XXX: I think $rch->reply should do this. -- rjbs, 2018-03-16
  $event->mark_handled;

  unless ($event->from_user) {
    $rch->reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  $text =~ s/\Aremind\s+//;
  my ($who, $prep, $dur_str, $want_page, $rest) = $text =~ qr/\A
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

  if ($want_page && ! $self->page_channel_name) {
    $rch->reply("Sorry, I can't send pages.");
    return;
  }

  my $to_user = $self->hub->user_directory
                          ->resolve_name($who, $event->from_user);

  unless ($to_user) {
    $rch->reply(qq{Sorry, I don't know who "$who" is.});
    return;
  }

  my $time;
  if ($prep eq 'in') {
    my $dur;
    $dur_str =~ s/^an?\s+/1 /;
    my $ok = eval { $dur = parse_duration($dur_str); 1 };
    return $fail->() unless $ok;
    $time = time + $dur;
  } elsif ($prep eq 'at') {
    my $dt = eval { parse_date_for_user($dur_str, $event->from_user) };
    return $fail->() unless $dt;
    $time = $dt->epoch;
  } else {
    return $fail->();
  }

  if ($time <= time) {
    $self->reply("That sounded like you want a reminder sent in the past.");
    return;
  }

  my $target = $to_user->username eq $event->from_user->username
             ? 'you'
             : $who->username;

  $self->add_reminder({
    when  => $time,
    body  => $rest,
    want_page => !! $want_page,
    from_username   => $event->from_user->username,
    to_channel_name => $event->from_channel->name,
    to_username     => $to_user->username,
  });

  $rch->reply(
    # XXX: use a better time formatter here -- rjbs, 2018-03-16
    sprintf "Okay, I'll remind %s at %s.", $target, scalar localtime $time
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

after _set_reminders => sub ($self) {
  $self->save_state;
};

has _next_timer => (
  is => 'rw',
  clearer => '_clear_next_timer',
);

sub add_reminder ($self, $reminder) {
  my @reminders = sort {; $a->{when} <=> $b->{when} }
                  ($reminder, $self->reminders);

  my $soonest = $reminders[0]{when};

  $self->_set_reminders(\@reminders);

  my $timer = $self->_next_timer;
  return if $timer && $timer->[0] == $soonest;

  $self->_clear_timer;
  $self->_setup_next_timer;
}

sub _clear_timer ($self) {
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
    my @to_channels = $reminder->{to_channel_name};
    push @to_channels, $self->page_channel_name if $reminder->{want_page};
    for my $channel_name (@to_channels) {
      $self->hub->channel_named($channel_name)->send_message_to_user(
        $self->hub->user_directory->user_named($reminder->{to_username}),
        "Reminder from $reminder->{from_username}: $reminder->{body}",
      );
    }
  }

  $self->_clear_timer;
  $self->_set_reminders(\@keep);
  $self->_setup_next_timer;

  return;
}

1;
