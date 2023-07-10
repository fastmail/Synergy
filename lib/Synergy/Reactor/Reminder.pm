use v5.32.0;
use warnings;
package Synergy::Reactor::Reminder;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use IO::Async::Timer::Absolute;
use List::Util qw(first);
use Time::Duration::Parse;
use Synergy::CommandPost;
use Synergy::Util qw(parse_date_for_user);

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

command remind => {
  help => "remind `{USER}` `{in, at, on}` `{TIME or DURATION}`: `{REMINDER TEXT}`",
} => async sub ($self, $event, $text) {
  unless ($event->from_user) {
    return await $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  my ($who, $prep, $dur_str, $want_page, $rest) = $text =~ qr/\A
    \s*
    (\S+)    # "me" or a nick
    \s+
    (in|at|on) # duration type
    \s+
    (.+?)    # duration
    (\s+with\s+page\s*)?
    :\s+     # the space is vital:  "at 15:15: eat pie"
    (.+)     # the reminder
    \z
  /xi;

  $_ = fc $_ for grep {; defined } ($who, $prep, $dur_str, $want_page);

  my $fail = async sub {
    return await $event->error_reply('usage: remind WHO (in|at|on) (time) [with page]: (reminder)');
  };

  unless (length $who and $prep) {
    return await $fail->();
  }

  if ($want_page && ! $self->page_channel_name) {
    return await $event->reply("Sorry, I can't send pages.");
  }

  my $to_user = $self->resolve_name($who, $event->from_user);

  unless ($to_user) {
    return await $event->error_reply(qq{Sorry, I don't know who "$who" is.});
  }

  my $time;
  $prep = 'at' if $prep eq 'on';  # "remind me at monday" is bogus

  if ($prep eq 'in') {
    my $dur;
    $dur_str =~ s/^an?\s+/1 /;
    my $ok = eval { $dur = parse_duration($dur_str); 1 };
    return await $fail->() unless $ok;
    $time = time + $dur;
  } elsif ($prep eq 'at') {
    my $dt = eval { parse_date_for_user($dur_str, $to_user) };
    return await $fail->() unless $dt;
    $time = $dt->epoch;
  } else {
    return await $fail->();
  }

  if ($time <= time) {
    return await $event->error_reply("That sounded like you want a reminder sent in the past.");
  }

  my $target = $to_user->username eq $event->from_user->username
             ? 'you'
             : $to_user->username;

  $self->add_reminder({
    when  => $time,
    body  => $rest,
    want_page => !! $want_page,
    from_username   => $event->from_user->username,
    to_channel_name => $event->from_channel->name,
    to_username     => $to_user->username,
  });

  return await $event->reply(
    sprintf "Okay, I'll remind %s at %s.",
      $target,
      $to_user->format_datetime( DateTime->from_epoch(epoch => $time) ),
  );
};

has reminders => (
  default   => sub {  []  },
  init_arg  => undef,
  writer    => '_set_reminders',
  traits    => [ 'Array' ],
  handles   => { reminders => 'elements' },
);

after _set_reminders => sub ($self, @) {
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
    notifier_name => 'reminder-due',
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
