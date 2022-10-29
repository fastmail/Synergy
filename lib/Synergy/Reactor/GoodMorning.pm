use v5.34.0;
use warnings;
package Synergy::Reactor::GoodMorning;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Synergy::Logger '$Logger';

use Synergy::CommandPost;
use Synergy::Util qw(pick_one);

use utf8;

my @BYE = (
  "See you later, alligator.",
  "After a while, crocodile.",
  "Time to scoot, little newt.",
  "See you soon, raccoon.",
  "Auf wiedertippen!",
  "Later.",
  "Peace.",
  "¡Adios!",
  "Au revoir.",
  "221 2.0.0 Bye",
  "+++ATH0",
  "Later, gator!",
  "Pip pip.",
  "Aloha.",
  "Farewell, %n.",
);

responder good_morning => {
  targeted => 1,
  matcher => sub {[]},
  help_titles => [ 'good morning', 'good evening' ],
  help    => 'be polite; say good morning or good night',
} => sub ($self, $event) {
  my $what = $event->text =~ s/\Pl//igr;
  $what = lc $what;
  $what =~ s/^go{2,}d/good/i;

  my $reply;

  if    ($what eq 'goodmorning')    { $reply  = "Good morning!"; }
  elsif ($what eq 'merrychristmas') { $reply  = "Bless us, every one!"; }
  elsif ($what eq 'happychristmas') { $reply  = "Bless us, every one!"; }
  elsif ($what eq 'happynewyear')   { $reply  = "\N{BOTTLE WITH POPPING CORK}"; }
  elsif ($what eq 'gday')           { $reply  = "How ya goin'?"; }
  elsif ($what eq 'gdaymate')       { $reply  = "How ya goin'?"; }
  elsif ($what eq 'grußgott')       { $reply  = "Doch, wenn du ihn siehst!"; }
  elsif ($what eq 'goodday')        { $reply  = "Long days and pleasant nights!"; }
  elsif ($what eq 'goodafternoon')  { $reply  = "You, too!"; }
  elsif ($what eq 'goodevening')    { $reply  = "I'll be here when you get back!"; }
  elsif ($what eq 'goodnight')      { $reply  = "Sleep tight!"; }
  elsif ($what eq 'goodriddance')   { $reply  = "I'll outlive you all."; }
  elsif ($what eq 'goodbye')        { $reply  = pick_one(\@BYE); }

  if ($reply) {
    $event->mark_handled;
    return $event->reply($reply);
  }

  return;
};

1;
