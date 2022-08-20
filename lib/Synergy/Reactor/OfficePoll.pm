use v5.28.0;
use warnings;
package Synergy::Reactor::OfficePoll;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use utf8;

use DateTime;
use IO::Async::Timer::Periodic;
use Synergy::Logger '$Logger';

# no listeners, just a timer
sub listener_specs {}

has primary_channel_name => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has channel => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) { $self->hub->channel_named($self->primary_channel_name) }
);

# something like....
# {
#   Australia/Sydney => #melbourne
#   America/New_York => #philly
# }

has time_zone_config => (
  is  => 'ro',
  isa => 'HashRef[Str]',
  required => 1,
  traits => ['Hash'],
  handles => {
    tz_names       => 'keys',
    address_for_tz => 'get',
  }
);

# timezone => epoch second
has _last_asked_times => (
  is => 'rw',
  init_arg => undef,
  default => sub { {} },
  traits => ['Hash'],
  handles => {
    last_time_for_tz => 'get',
    note_ask_for_tz  => 'set',
  }
);

after note_ask_for_tz => sub ($self, @) {
  $self->save_state;
};


sub state ($self) {
  return {
    last_asked_times => $self->_last_asked_times,
  };
}

after register_with_hub => sub ($self, @) {
  my $state = $self->fetch_state;
  return unless $state;

  if (my $times = $state->{last_asked_times}) {
    $self->_last_asked_times($times);
  }
};

sub start ($self) {
  my $timer = IO::Async::Timer::Periodic->new(
    notifier_name => 'office-poll-timer',
    interval => 15 * 60,
    first_interval => 10,
    on_tick  => sub { $self->maybe_ask },
  );

  $self->hub->loop->add($timer->start);
}

my %next_weekday_for = (
  Monday    => 'Tuesday',
  Tuesday   => 'Wednesday',
  Wednesday => 'Thursday',
  Thursday  => 'Friday',
  Friday    => 'Monday',
);

sub maybe_ask ($self) {
  state @options = (
    ":white_check_mark: Yes",
    ":people_holding_hands:  Yes, if other people will be there",
    ":thinking_face: I'm not sure yet",
    ":negative_squared_cross_mark: No",
  );

  for my $tz ($self->tz_names) {
    my $recent = $self->last_time_for_tz($tz) // 0;
    next if time - $recent < 86400 - (15 * 60);   # don't ask more than 1x a day

    $Logger->log("will ask about office attendance in $tz");

    my $now = DateTime->now(time_zone => $tz);
    my $tomorrow = $next_weekday_for{ $now->day_name };

    unless ($tomorrow) {
      # tomorrow's not a weekday; just record that we asked
      $self->note_ask_for_tz($tz, time);
      next;
    }

    # Ask the first tick after 2pm
    next unless $now->hour >= 14;

    my $when_str = $tomorrow eq 'Monday'
                 ? 'on Monday'
                 : "tomorrow ($tomorrow)";

    my $text = ":question: Are you coming into the office $when_str?\n";
    $text    .= join q{  /  }, @options;

    my $address = $self->address_for_tz($tz);

    $self->channel->send_message($address, $text);
    $self->note_ask_for_tz($tz, time);
  }
}

1;
