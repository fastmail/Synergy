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

sub listener_specs {
  return {
    name      => 'clox',
    method    => 'handle_clox',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->was_targeted;
      return unless $e->text =~ /\Aclo(?:x|cks)(?:\s+.+)?/i;
    },
  };
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
      unless $time = parse_date_for_user($spec, $event->from_user);
  } else {
    $time = $NOW_FACTORY->();
  }

  # Some of our australian colleagues feel very strongly about being able to
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

1;
