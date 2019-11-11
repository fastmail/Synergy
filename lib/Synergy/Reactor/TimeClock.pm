use v5.24.0;
use warnings;
package Synergy::Reactor::TimeClock;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences',
     ;

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Synergy::Logger '$Logger';

use List::Util qw(max);

use utf8;

sub listener_specs {
  return; # for now
}

has primary_channel_name => (
  is  => 'ro',
  isa => 'Str',
  required => 1, # TODO: die during registration if ∄ channel
);

sub state ($self) {
  return {
    last_report_time => $self->last_report_time,
  };
}

sub start ($self) {
  my $timer = IO::Async::Timer::Periodic->new(
    interval => 15 * 60,
    on_tick  => sub { $self->check_for_shift_changes; },
  );

  $self->hub->loop->add($timer);

  $timer->start;

  $self->check_for_shift_changes;
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $epoch = $state->{last_report_time}) {
      $self->last_report_time($epoch);
    }
  }
};

has last_report_time => (
  is   => 'rw',
  isa  => 'Int',
  lazy => 1,
  default => $^T - 900
);

sub check_for_shift_changes ($self) {
  my $report_reactor = $self->hub->reactor_named('report');
  return unless $report_reactor; # TODO: fatalize during startup..?

  my $channel = $self->hub->channel_named($self->primary_channel_name);

  # Okay, here's the deal.  We want to remind people of their civic duty, which
  # means telling them:
  #
  # * shortly after shift starts, what work is on their plate for the day
  # * shortly before shift ends,  whether they have missed key work
  #
  # We want to find people who have come on duty in the last 15m, unless we've
  # already sent a report in the last 15m.  Also, anyone who will end their
  # shift in the next 30m, unless we already covered that time.
  #
  # If we've been offline for a good long time (oh no!) let's not give people
  # reports that are more than two hours overdue.  First off, it's just polite.
  # Secondly, it will prevent us from doing weird things like sending both
  # morning and evening reports. -- rjbs, 2019-11-08
  my $now  = time;
  my $last = max($self->last_report_time, $now - 7200);

  my %if = (
    morning => sub ($s, $e) { $s > $last        && $s <= $now },
    evening => sub ($s, $e) { $e > $last + 1800 && $e <= $now + 1800 },
  );

  my %report = map {; $_ => $report_reactor->report_named($_) } keys %if;

  return unless grep {; defined } values %report;

  my $now_dt = DateTime->from_epoch(epoch => $now);

  USER: for my $user ($self->hub->user_directory->users) {
    next unless $user->has_identity_for($channel->name);

    next unless my $shift = $user->shift_for_day($now_dt);

    for my $which (sort keys %if) {
      next unless $if{$which}->($shift->@{ qw(start end) });

      my $report = $report_reactor->begin_report($report{$which}, $user);

      my ($text, $alts) = $report->get;

      next unless defined $text; # !? -- rjbs, 2019-10-29

      $Logger->log([ "sending %s report for %s", $which, $user->username ]);
      $channel->send_message_to_user($user, $text, $alts);

      next USER;
    }
  }

  $self->last_report_time($now);
  $self->save_state;
}

1;
