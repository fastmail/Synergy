use v5.24.0;
use warnings;
package Synergy::Reactor::LiquidPlanner;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::ProvidesUserStatus',
     ;

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Synergy::Logger '$Logger';

use utf8;

has primary_channel_name => (
  is  => 'ro',
  isa => 'Str',
);

sub state ($self) {
  return {
    last_morning_report_time => $self->last_morning_report_time,
  };
}

sub start ($self) {
  my $good_morning_timer = IO::Async::Timer::Periodic->new(
    interval => 15 * 60,
    on_tick  => sub ($timer, @arg) { $self->check_for_good_mornings($timer); },
  );

  $self->hub->loop->add($good_morning_timer);

  $good_morning_timer->start;

  $self->check_for_good_mornings;
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $epoch = $state->{last_morning_report_time}) {
      $self->last_morning_report_time($epoch);
    }
  }
};

has last_morning_report_time => (
  is => 'rw',
  isa => 'Int',
);

sub check_for_good_mornings ($self, $ = undef) {
  my $channel = $self->hub->channel_named($self->primary_channel_name);
  return unless $channel;

  my $report_reactor = $self->hub->reactor_named('report');
  my $morning = $report_reactor->report_named('morning');
  return unless $morning;

  my $last = $self->last_morning_report_time // time - 15*60;

  for my $user ($self->hub->user_directory->users) {
    next unless $user->has_identity_for($channel->name);
    next unless $user->has_started_work_since($last);

    my $report = $report_reactor->begin_report($morning, $user);

    my ($text, $alts) = $report->get;

    next unless defined $text; # !? -- rjbs, 2019-10-29

    $Logger->log([ "sending %s the morning report", $user->username ]);
    $channel->send_message_to_user($user, $text, $alts);
  }

  $self->last_morning_report_time(time);
  $self->save_state;
}

1;
