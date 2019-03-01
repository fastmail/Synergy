use v5.24.0;
use warnings;
package Synergy::Reactor::DC;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(lexical_subs signatures);
use namespace::clean;
use File::pushd;
use File::Find;
use Path::Tiny;

has has_dc => (
  is => 'ro',
  isa => 'Bool',
  lazy => 1,
  default => sub {
    `dc -e '1 1 +p'` eq "2\n";
  },
);

sub listener_specs {
  return {
    name      => 'DC',
    method    => 'handle_dc',
    predicate => sub ($self, $e) {
      $e->was_targeted && $e->text =~ /^dc\s+/i;
    },
    help_entries => [
      { title => 'dc', text => "dc [commands] - Execute [commands] with the dc calculator" },
    ],
  },
}

sub handle_dc($self, $event) {
  $event->mark_handled;

  unless ($self->has_dc) {
    return $event->reply("Sorry, `dc` does not appear to be installed on this system");
  }

  my ($cmd) = $event->text =~ /^dc\s+(?:-e\s+)?'?(.*?)'?\s*$/i;
  unless ($cmd) {
    return $event->reply("Sory, I didn't understand that. Try: dc -e '1 2 +p', for example");
  }

  if ($cmd =~ /!(?![<=>])/) {
    return $event->reply("Sorry, but !<system command> is *not* allowed");
  }

  my $resp;

  my $process = IO::Async::Process->new(
    command => [ 'dc', '-e', $cmd ],
    stdout => {
      on_read => sub {
        my ( $stream, $buffref ) = @_;

        $resp .= $$buffref;
        $$buffref = "";

        return 0;
      },
    },
    stderr => {
      on_read => sub {
        my ( $stream, $buffref ) = @_;

        $resp .= $$buffref;
        $$buffref = "";

        return 0;
      },
    },
    on_finish => sub {
      chomp($resp);

      if (split(/\n/, $resp) > 1) {
        $event->reply("```$resp```");
      } else {
        $event->reply($resp);
      }
    },
    on_exception => sub ($self, $exception, $errno, $exitcode) {
      $event->reply("Sorry, dc exited unexpectedly? (E: $exception, ERRNO: $errno, EC: $exitcode)");
    }
  );

  $self->hub->loop->add($process);

  return;
}

1;
