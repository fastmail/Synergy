use v5.36.0;
package Synergy::Reactor::Roll;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use Games::Dice qw(roll_array);
use List::Util qw(sum);
use Synergy::CommandPost;

command roll => {
  help => '*roll SPEC*: roll some dice, D&D style (roll 2d6, roll 1d20)',
} => async sub ($self, $event, $spec) {
  unless ($spec) {
    return await $event->error_reply("usage: roll DICE-SPEC");
  }

  my ($total, $rolls) = $self->_roll($spec);
  unless ($total) {
    return await $event->error_reply(qq{Sorry, I can't roll those sorts of dice.});
  }

  my $result = @$rolls == 1
             ? "$total"
             : "$total [". join(', ', @$rolls) . "]";

  await $event->reply("rolled $spec = $result");
};

# This is lifted from Games::Dice, but returns the actual dice rolls too.
sub _roll ($self, $line) {
  my ($dice_string, $sign, $offset, $sum, @throws, @result);

  return $line if $line =~ /\A[0-9]+\z/;

  return undef unless $line =~ m{
             ^              # beginning of line
             (              # dice string in $1
               (?:\d+)?     # optional count
               [dD]         # 'd' for dice
               (?:          # type of dice:
                  \d+       # either one or more digits
                |           # or
                  %         # a percent sign for d% = d100
                |           # pr
                  F         # a F for a fudge dice
               )
             )
             (?:            # grouping-only parens
               ([-+xX*/bB]) # a + - * / b(est) in $2
               (\d+)        # an offset in $3
             )?             # both of those last are optional
             \s*            # possibly some trailing space (like \n)
             $
          }x;               # whitespace allowed

  $dice_string = $1;
  $sign        = $2 || '';
  $offset      = $3 || 0;

  $sign        = lc $sign;

  @throws = roll_array($dice_string);
  return undef unless @throws;

  if ($sign eq 'b') {
    $offset = 0       if $offset < 0;
    $offset = @throws if $offset > @throws;

    @throws = sort { $b <=> $a } @throws;   # sort numerically, descending
    @result = @throws[ 0 .. $offset-1 ];    # pick off the $offset first ones
  } else {
    @result = @throws;
  }

  $sum = 0;
  $sum += $_ foreach @result;
  $sum += $offset if  $sign eq '+';
  $sum -= $offset if  $sign eq '-';
  $sum *= $offset if ($sign eq '*' || $sign eq 'x');
  do { $sum /= $offset; $sum = int $sum; } if $sign eq '/';

  return $sum, \@throws;
}

1;
