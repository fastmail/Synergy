use v5.24.0;
package Synergy::Reactor::Clox;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
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
      return unless $e->text =~ /\Aclox(?:\s+.+)?/; },
  };
}

sub handle_clox ($self, $event) {
  $event->mark_handled;

  my (undef, $spec) = split /\s+/, $event->text, 2;

  my $time;
  if ($spec) {
    return $event->reply(qq{Sorry, I couldn't understand the time "$time".})
      unless $time = parse_date_for_user($spec, $event->from_user);
  } else {
    $time = DateTime->now;
  }

  my @tzs = sort {; $a cmp $b }
            uniq
            grep {; defined }
            map  {; $_->time_zone }
            $self->hub->user_directory->users;

  @tzs = ('America/New_York') unless @tzs;

  my $tz_nick = $self->hub->time_zone_names;
  my $user_tz = ($event->from_user && $event->from_user->time_zone)
             // '';

  my @times;

  my @tz_objs = map {; DateTime::TimeZone->new(name => $_) } @tzs;

  for my $tz (
    sort {; $a->offset_for_datetime($time) <=> $b->offset_for_datetime($time) }
    @tz_objs
  ) {
    my $tz_name = $tz->name;
    my $tz_time = $time->clone;
    $tz_time->set_time_zone($tz);

    my $str = $self->hub->format_friendly_date(
      $tz_time,
      {
        include_time_zone => 0,
        target_time_zone  => $event->from_user->time_zone,
      }
    );

    my $nick = $tz_nick->{$tz_name} // $tz->name;
    $str = "$nick $str";

    $str .= " \N{LEFTWARDS ARROW} you are here"
      if $tz_name eq $user_tz;

    push @times, $str;
  }

  my $sit = $time->clone;
  $sit->set_time_zone('+0100');

  my $beats
    = $sit->ymd('-') . '@'
    . int(($sit->second + $sit->minute * 60 + $sit->hour * 3600) / 86.4);

  my $its = $spec ? "$spec is" : "it's";

  my $reply = "In Internet Time\N{TRADE MARK SIGN} $its $beats.  That's...\n";
  $reply .= join q{}, map {; "> $_\n" } @times;

  $event->reply($reply);
}

1;
