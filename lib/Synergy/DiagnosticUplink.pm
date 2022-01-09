use v5.28.0;
use warnings;
package Synergy::DiagnosticUplink;

use Moose;
use experimental qw(lexical_subs signatures);
use utf8;

use Synergy::Logger '$Logger';

require JSON;
my $JSON = JSON->new;

with 'Synergy::Role::HubComponent';

has port => (is => 'ro', required => 1);
has host => (is => 'ro', default => '127.0.0.1');

has color_scheme => (is => 'ro');

package Synergy::DiagnosticUplink::Connection {
  use parent 'IO::Async::Stream';

  use experimental qw(lexical_subs signatures);

  use Synergy::DiagnosticHandler;

  sub configure ($self, %param) {
    my $hub = delete $param{hub};

    $self->{Synergy_DiagnosticUplink_hub} = $hub;

    return $self->SUPER::configure(%param);
  }

  sub _diagnostic_handler ($self) {
    $self->{Synergy_DiagnosticUplink_handler} //= do {
      my $color_scheme = $self->{Synergy_DiagnosticUplink_hub}
                              ->diagnostic_uplink
                              ->color_scheme;

      my $diag = Synergy::DiagnosticHandler->new({
        allow_eval => 1,
        stream => $self,
        hub    => $self->{Synergy_DiagnosticUplink_hub},

        ($color_scheme ? (color_scheme => $color_scheme) : ()),
      });
    };
  }

  sub on_read ($self, $buffref, $eof) {
    while ($$buffref =~ s/^(.*\n)//) {
      my $line = $1;
      chomp $line;

      my $ok = $self->_diagnostic_handler->_do_diagnostic_command($line);

      unless ($ok) {
        $self->write("Command unknown.\n");
      }
    }

    return 0;
  }

  no Moose;
}

sub start ($self) {
  my $hub = $self->hub;

  my $listener = IO::Async::Listener->new(
    handle_class => 'Synergy::DiagnosticUplink::Connection',
    on_accept    => sub ($, $stream, @) {
      $stream->configure(
        encoding => 'UTF-8',
        hub      => $hub,
      );

      $self->loop->add($stream);

      $stream->write("Diagnostic interface online.\n");
      return;
    },
  );

  $self->loop->add($listener);

  $listener->listen(
    addr => {
      family   => "inet",
      socktype => "stream",
      port     => $self->port,
      ip       => $self->host,
    }
  )->get;

  return;
}

no Moose;

1;
