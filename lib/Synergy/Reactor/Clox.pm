use v5.32.0;
use warnings;
package Synergy::Reactor::Clox;

use Moose;

with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use Synergy::CommandPost;

use experimental qw(signatures lexical_subs);

use DateTime;
use Future::AsyncAwait;
use List::Util qw(first uniq);
use Synergy::Util qw(parse_date_for_user);
use Time::Duration::Parse;

use utf8;

# For testing. -- rjbs, 2018-07-14
our $NOW_FACTORY = sub { DateTime->now };

__PACKAGE__->add_preference(
  name        => 'include-aelt',
  help        => "Whether or not to include AELT in the output",
  description => "Whether or not to include AELT in the output",
  describer   => async sub ($value) { $value ? 1 : 0 },
  validator   => async sub ($self, $value, $event) {
    return(($value ? 1 : 0), undef); # Should write a generic bool/yes/no.
  },
  default     => 0,
);

has always_include => (
  isa     => 'ArrayRef',
  default => sub {  []  },
  traits  => [ 'Array' ],
  handles => { always_include => 'elements' },
);

has include_aelt => (
  isa => 'Bool',
  is  => 'ro',
  default => 0,
);

sub _aelt_delta_for_time ($self, $dt) {
  my $sun_brisbane = DateTime::Event::Sunrise->new(
    latitude  => -27.467778, # south
    longitude => 153.028056, # east
  );

  my $local = $dt->clone->set_time_zone('Australia/Brisbane');
  my $date  = $local->clone->truncate(to => 'day');

  my $ohseven = $date->clone->set_hour(7);

  my $sunrise_epoch = $sun_brisbane->sunrise_datetime($date)->epoch;
  my $epoch_diff    = $ohseven->epoch - $sunrise_epoch;
}

command clox => {
  help => <<'END'
*clox* tells you what time it is in any time zone with a user in it (or that
has been set up to always show up in the clocks).  You can also write:

• *clox `TIME`*: when it's the given time _for you_, see the time elsewhere
END
} => sub ($self, $event, $spec) {
  my $user = $event->from_user;

  # Some of our Australian colleagues feel very strongly about being able to
  # write 'Australia/Melbourne' rather than 'Australia/Sydney'.
  my sub mel_to_syd ($tzname) {
    return $tzname eq 'Australia/Melbourne' ? 'Australia/Sydney' : $tzname;
  }

  my $time;
  my $user_tz;
  my $prefix;

  if ($user) {
    $user_tz = mel_to_syd($user->time_zone);
  } else {
    $user_tz = q{America/New_York};
    $prefix  = "I don't know who you are, so I'm assuming you're in Philadelphia.";
  }

  if (length $spec) {
    return $event->error_reply(qq{Sorry, I couldn't understand the time "$time".})
      unless $time = parse_date_for_user($spec, $user, 1);
  } else {
    $time = $NOW_FACTORY->();
  }

  my @tzs = sort {; $a cmp $b }
            uniq
            map  {; mel_to_syd($_) }
            grep {; defined }
            ( $self->always_include,
              ( grep {; defined }
                map  {; $_->time_zone }
                $self->hub->user_directory->users));

  @tzs = ('America/New_York') unless @tzs;

  my $tz_nick = $self->hub->env->time_zone_names;

  my %tz_objs = map {; $_ => DateTime::TimeZone->new(name => $_) } @tzs;

  my $home_offset = $tz_objs{$user_tz}->offset_for_datetime($time);

  my @strs;

  for my $tz (
    sort {; $a->offset_for_datetime($time) <=> $b->offset_for_datetime($time) }
    values %tz_objs
  ) {
    my $tz_name = $tz->name;

    my $tz_time = DateTime->from_epoch(
      time_zone => $user_tz,
      epoch     => $time->epoch
                -  $home_offset
                +  $tz->offset_for_datetime($time),
    );

    my $str = $self->hub->format_friendly_date(
      $tz_time,
      {
        include_time_zone => 0,
        target_time_zone  => $user_tz,
      }
    );

    my $nick = $tz_nick->{$tz_name} // ($tz->name . ": ");
    $str = "$nick $str";

    $str .= " \N{LEFTWARDS ARROW} you are here"
      if $tz_name eq $user_tz;

    push @strs, $str;
  }

  my $want_aelt = $self->include_aelt
    && $self->get_user_preference($user, 'include-aelt');

  if ($want_aelt && eval { require DateTime::Event::Sunrise }) {
    my $brisbane_tz = DateTime::TimeZone->new(name => 'Australia/Brisbane');

    my $aelt = $self->_aelt_delta_for_time($time);
    my $tz_time = DateTime->from_epoch(
      time_zone => $user_tz,
      epoch     => $time->epoch
                -  $home_offset
                +  $brisbane_tz->offset_for_datetime($time)
                -  $aelt,
    );

    push @strs, "AELT " . $self->hub->format_friendly_date(
      $tz_time,
      {
        include_time_zone => 0,
        target_time_zone  => $user_tz,
      }
    );
  }

  my $sit = $time->clone;
  $sit->set_time_zone('+0100');

  my $beats = sprintf '%s@%03u',
    $sit->ymd('-'),
    int(($sit->second + $sit->minute * 60 + $sit->hour * 3600) / 86.4);

  my $its = $spec ? "$spec is" : "it's";

  my $reply = "In Internet Time\N{TRADE MARK SIGN} $its $beats.  That's...\n";
  $reply = "$prefix\n\n$reply" if length $prefix;
  $reply .= join q{}, map {; "> $_\n" } @strs;

  chomp $reply;

  my $slack = $reply =~ s/AELT /:flag-brisbane: /r;

  $event->reply($reply, { slack => $slack });
};

command when => {
  help => <<'END'
*when is `WHEN`*: tells you how the given "when" string would be interpreted
END
} => sub ($self, $event, $rest) {
  return $event->reply_error("Sorry, I don't understand your *when* request.")
    unless $rest =~ s/\Ais\s+//;

  if ($rest =~ s/\Anow\s+(plus|\+|-|minus)\s+//) {
    my $sign = ($1 eq '+' || $1 eq 'plus') ? 1 : -1;
    my $now  = time;
    my $dur  = parse_duration($rest);

    return $event->reply_error("Sorry, I don't understand that duration.")
      unless defined $dur;

    my $time = $now + ($sign * $dur);

    my $str = $self->hub->format_friendly_date(
      DateTime->from_epoch(epoch => $time, time_zone => 'UTC'),
      {
        target_time_zone  => $event->from_user->time_zone,
      }
    );

    return $event->reply("That would be: $str");
  }

  my $time = parse_date_for_user($rest, $event->from_user);

  return $event->reply("Sorry, I didn't understand that time.")
    unless $time;


  my $str = $self->hub->format_friendly_date(
    $time,
    {
      target_time_zone  => $event->from_user->time_zone,
    }
  );

  return $event->reply("That would be: $str");
};

1;
