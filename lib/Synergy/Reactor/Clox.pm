use v5.24.0;
use warnings;
package Synergy::Reactor::Clox;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use List::Util qw(first uniq);
use Synergy::Util qw(parse_date_for_user);
use Time::Duration::Parse;

use utf8;

sub listener_specs {
  return (
    {
      name      => 'clox',
      method    => 'handle_clox',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ /\Aclo(?:x|cks)(?:\s+.+)?/i;
      },
      help_entries => [
        # I wanted to use <<~'END' but synhi gets confused. -- rjbs, 2020-09-23
        { title => 'clox', text => <<'END'
*clox* tells you what time it is in any time zone with a user in it (or that
has been set up to always show up in the clocks).  You can also write:

• *clox `TIME`*: when it's the given time _for you_, see the time elsewhere
END
        },
      ],
    },
    {
      name      => 'when',
      method    => 'handle_when',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ /\Awhen\s+is\s+/i;
      },
      help_entries => [
        # I wanted to use <<~'END' but synhi gets confused. -- rjbs, 2020-09-23
        { title => 'when', text => <<'END'
*when is `WHEN`*: tells you how the given "when" string would be interpreted
END
        },
      ],
    },
  );
}

# For testing. -- rjbs, 2018-07-14
our $NOW_FACTORY = sub { DateTime->now };

has always_include => (
  isa     => 'ArrayRef',
  default => sub {  []  },
  traits  => [ 'Array' ],
  handles => { always_include => 'elements' },
);

sub handle_clox ($self, $event) {
  $event->mark_handled;

  my (undef, $spec) = split /\s+/, $event->text, 2;

  my $time;
  if ($spec) {
    return $event->error_reply(qq{Sorry, I couldn't understand the time "$time".})
      unless $time = parse_date_for_user($spec, $event->from_user, 1);
  } else {
    $time = $NOW_FACTORY->();
  }

  # Some of our Australian colleagues feel very strongly about being able to
  # write 'Australian/Melbourne' rather than 'Australia/Sydney'.
  my sub mel_to_syd ($tzname) {
    return $tzname eq 'Australia/Melbourne' ? 'Australia/Sydney' : $tzname;
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
  my $user_tz = mel_to_syd($event->from_user->time_zone);

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

  my $sit = $time->clone;
  $sit->set_time_zone('+0100');

  my $beats = sprintf '%s@%03u',
    $sit->ymd('-'),
    int(($sit->second + $sit->minute * 60 + $sit->hour * 3600) / 86.4);

  my $its = $spec ? "$spec is" : "it's";

  my $reply = "In Internet Time\N{TRADE MARK SIGN} $its $beats.  That's...\n";
  $reply .= join q{}, map {; "> $_\n" } @strs;

  $event->reply($reply);
}

sub handle_when ($self, $event) {
  $event->mark_handled;

  my $text = $event->text;

  return $event->reply_error("Sorry, I don't understand your *when* request.")
    unless $text =~ s/\Awhen\s+is\s+//;

  if ($text =~ s/\Anow\s+(plus|\+|-|minus)\s+//) {
    my $sign = ($1 eq '+' || $1 eq 'plus') ? 1 : -1;
    my $now  = time;
    my $dur  = parse_duration($text);

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

  my $time = parse_date_for_user($text, $event->from_user);

  return $event->reply("Sorry, I didn't understand that time.")
    unless $time;


  my $str = $self->hub->format_friendly_date(
    $time,
    {
      target_time_zone  => $event->from_user->time_zone,
    }
  );

  return $event->reply("That would be: $str");
}

1;
