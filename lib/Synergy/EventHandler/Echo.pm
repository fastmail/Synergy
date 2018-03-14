use v5.24.0;
package Synergy::EventHandler::Echo;

use Moose;
with 'Synergy::Role::EventHandler';

use experimental qw(signatures);
use namespace::clean;

my $OWN_NAME = $ENV{SYNERGY_NAME};

sub start { }

sub handle_event ($self, $event, $rch) {
  return unless $event->type eq 'message';

  # here, handle LP12345678 & "you're back!"

  return unless $event->text =~ /^\@?$OWN_NAME\W/;

  my $rn;

  if ($event->user) {
    $rn = "%s, (" . $event->user->realname . ")";
  } else {
    $rn = "%s";
  }

  my $response = sprintf "I heard you, $rn. You said \"%s\"",
    $event->from,
    $event->text;

  $rch->reply($response);

  return 1;
}

1;
