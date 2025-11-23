#!perl
use v5.28.0;
use warnings;
use experimental 'signatures';

use lib 'lib', 't/lib';

use Synergy::Rototron2;
use Test::More;

use Synergy::Logger::Test '$Logger';

my $ezra_rotor = Synergy::Rototron2::Rotor->new({
  name   => 'be ezra',
  ident  => 'ezra',
  people_preferences => {
    ezra    => 1,
    whitney => 99,
  }
});

my $lunch_rotor = Synergy::Rototron2::Rotor->new({
  name   => 'order lunch',
  ident  => 'lunch',
  people_preferences => {
    hayden => 1, # almost always this person!
    bailey => 2,
    dana   => 2,
    finley => 2,
    kim    => 2,
  }
});

my $sweep_rotor = Synergy::Rototron2::Rotor->new({
  name   => 'sweep the floor',
  ident  => 'sweep',
  people_preferences => {
    aiden  => 1,
    bailey => 1,
    chaz   => 1,
    dana   => 1,
    ezra   => 2, # fallback sweepist
  }
});

my $trash_rotor = Synergy::Rototron2::Rotor->new({
  name   => 'take out the trash',
  ident  => 'trash',
  people_preferences => {
    aiden  => 2, # fallback trash taker-outer
    chaz   => 1,
    ezra   => 1,
    finley => 1,
    grey   => 1,
  }
});

my $rototron = Synergy::Rototron2->new({
  rotors => [ $ezra_rotor, $sweep_rotor, $trash_rotor, $lunch_rotor ],
  availability_checker => sub ($person, $dt) {
    # Happy Birthday, Ezra!
    return if $person eq 'ezra' && $dt->ymd eq '2022-01-11';

    return 1;
  },
});

my sub ymd ($year, $month, $day) {
  return DateTime->new(
    time_zone => 'UTC',
    year      => $year,
    month     => $month,
    day       => $day,
  );
}

my $first_monday = ymd(2022, 1, 3);

$Synergy::Rototron2::FATIGUE_BACKSTOP = '2022-01-01';

# Basic setup, everybody is bright eyed and bushy tailed.
$rototron->schedule_range($first_monday, 6);

# Now we should see fatigue.
$rototron->schedule_range($first_monday->clone->add(days => 7), 6);

done_testing;
