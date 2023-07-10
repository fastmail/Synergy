use v5.32.0;
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
    while ($$buffref =~ s/^(.*?)\R//) {
      my $line = $1;

      my $ok = $self->_diagnostic_handler->_do_diagnostic_command($line);

      unless ($ok) {
        $self->write("Command unknown.\n");
      }
    }

    return 0;
  }

  no Moose;
}

sub banner_message {
  my sub rstr ($str, $rev = 0) {
    my @col = (9, 11, 209, 10, 14, 12, 99);
    @col = reverse @col if $rev;

    join q{}, map {; Term::ANSIColor::colored([ "ansi$_" ], $str . ' ') } @col;
  }

  my sub line ($col, $line) {
    Term::ANSIColor::colored(["ansi$col"], sprintf '%-40s', $line)
  }

  my $tl = q{⎛};  # q{//}
  my $ml = q{⎜};  # q{||}
  my $bl = q{⎝};  # q{\\\\}
  my $tr = q{⎞};  # q{\\\\}
  my $mr = q{⎟};  # q{||}
  my $br = q{⎠};  # q{//}

  join qq{\n},
    "",
    "  "
      . rstr($tl)
      . "    "
      . line(99, 'Synergy Diagnostic Uplink')
      . rstr($tr, 1),
    "  "
      . rstr($ml)
      . "    "
      . line(15, 'Try /help for help')
      . rstr($mr, 1),
    "  "
      . rstr($bl)
      . "    "
      . line(15, 'For more information, please reread.')
      . rstr($br, 1),
    "",
    "";
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

      $stream->write(
        # Synergy::TextThemer->null_themer->_format_box(
          $self->banner_message
        # )
      );
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
