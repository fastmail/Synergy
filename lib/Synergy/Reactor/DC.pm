use v5.32.0;
use warnings;
package Synergy::Reactor::DC;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(lexical_subs signatures);
use namespace::clean;

use Future::AsyncAwait;
use File::pushd;
use File::Find;
use Path::Tiny;
use Synergy::CommandPost;

has has_dc => (
  is => 'ro',
  isa => 'Bool',
  lazy => 1,
  default => sub {
    `dc -e '1 1 +p'` eq "2\n";
  },
);

command dc => {
  help => "*dc* `DC-COMMANDS...`: execute commands with the dc calculator",
} => async sub ($self, $event, $commands) {
  unless ($self->has_dc) {
    return await $event->reply("Sorry, `dc` does not appear to be installed on this system");
  }

  my ($cmd) = $event->text =~ /^dc\s+(?:-e\s+)?'?(.*?)'?\s*$/i;
  unless (length ($cmd // '')) {
    return await $event->reply("Sory, I didn't understand that. Try: dc -e '1 2 +p', for example");
  }

  if ($cmd =~ /!(?![<=>])/) {
    return await $event->reply("Sorry, but !<system command> is *not* allowed");
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
    on_finish => sub ($pid, $exitcode) {
      my $status = ( $exitcode >> 8 );

      chomp($resp);

      if ($status) {
        $event->reply("Sorry, dc exited unexpectedly? (EC: $exitcode, S: $status, OUTPUT: $resp)");

        return;
      } elsif ($exitcode) {
        $event->reply("Sorry, dc terminated on signal $exitcode");

        return;
      } elsif (! length($resp // '' )) {
        $event->reply("<no output>");

        return;
      }

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

  my $timer = IO::Async::Timer::Countdown->new(
    delay => 5,
    notifier_name    => 'dc-timeout',
    remove_on_expire => 1,
    on_expire => sub {
      $process->is_running && $process->kill('KILL');
    },
  );

  $timer->start;

  $self->hub->loop->add($timer);

  return;
};

1;
