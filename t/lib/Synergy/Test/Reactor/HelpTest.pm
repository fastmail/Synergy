use v5.36.0;
package Synergy::Test::Reactor::HelpTest;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::X;

command widget => {
  aliases => [ 'gadget' ],
  help    => "*widget `THING`*: do something with a widget",
  parser  => sub ($, $text, $) {
    # Like many real parsers, this one would reject "help".
    Synergy::X->throw_public("I don't know that widget.") unless $text eq 'spin';
    return [ $text ];
  },
} => async sub ($self, $event, $thing) {
  await $event->reply("The widget does: $thing");
};

command parrot => {
  help => "*parrot `TEXT`*: say it back",
  help_subcommand => 0,
} => async sub ($self, $event, $rest) {
  await $event->reply("Squawk: $rest");
};

1;
