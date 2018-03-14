use v5.24.0;
package Synergy::EventHandler::Clox;

use Moose;
use DateTime;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

sub start { }

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';
  return unless $event->was_targeted;
  return unless $event->text =~ /^clox/;

  my $now = DateTime->now;

  # TODO: get from config
  my @tzs = ('America/New_York', 'Australia/Sydney', 'Asia/Kolkata');
  my @times;

  for my $tz_name (@tzs) {
    my $tz = DateTime::TimeZone->new(name => $tz_name);
    my $tz_now = $now->clone;
    $tz_now->set_time_zone($tz);

    push @times, $tz_now->day_name . ", " . $tz_now->format_cldr("H:mm vvv");
  }

  my $sit = $now->clone;
  $sit->set_time_zone('+0100');

  push @times, $sit->ymd('-') . '@'
      . int(($sit->second + $sit->minute * 60 + $sit->hour * 3600) / 86.4);

  $rch->reply(join('; ', @times));
  return 1;
}

1;
