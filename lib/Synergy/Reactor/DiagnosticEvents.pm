use v5.32.0;
use warnings;
package Synergy::Reactor::DiagnosticEvents;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::X;

command 'diag-die' => {
  help => '*diag-die*: reacts by throwing a string exception',
} => async sub ($self, $event, $rest) {
  die "This exception was caused on purpose by diag-die.";
};

command 'diag-die-x' => {
  help => '*diag-die-x*: reacts by throwing a public Synergy::X exception',
} => async sub ($self, $event, $rest) {
  Synergy::X->throw_public("This exception was caused on purpose via a Synergy::X thrown by diag-die-x.");
};

1;
