#!perl
use v5.32.0;
use warnings;

package Synergy::Tester;

use experimental 'signatures';

use Synergy::Logger::Test '$Logger';

use Defined::KV;
use Net::EmptyPort qw(empty_port);

my sub _test_logger {
  Synergy::Logger->default_logger_class->new({
    ident     => "synergy-tester",
    to_self   => 1,
    facility  => undef,
    log_pid   => 0,
    to_stderr => !! Synergy::Logger->default_logger_class->env_value('STDERR'),
    to_tap    => !! Synergy::Logger->default_logger_class->env_value('TAP'),
  });
}

package Synergy::Tester::Result {
  use Moose;

  has synergy => (is => 'ro');
  has logger  => (is => 'ro');

  no Moose;
  __PACKAGE__->meta->make_immutable;
}

package Synergy::Tester::Hub {
  use Moose;
  extends 'Synergy::Hub';

  use Synergy::Logger '$Logger';

  use IO::Async::Test;

  sub test_channel ($self) {
    return $self->channel_named('test-channel');
  }

  sub run_test_program ($self, $todo) {
    local $Logger = _test_logger;

    $self->test_channel->queue_todo($_) for $todo->@*;

    testing_loop($self->loop);

    wait_for {
      return unless $self->test_channel->is_exhausted;

      my @events = grep {; ! $_->{event}->completeness->is_ready }
                   $self->_events_in_flight;

      return if @events;

      return 1;
    };

    return Synergy::Tester::Result->new({
      synergy => $self,
      logger  => $Logger,
    });
  }

  no Moose;
  __PACKAGE__->meta->make_immutable;
}

sub new_tester {
  my ($class, $arg) = @_;

  local $Logger = _test_logger;

  my $synergy = Synergy::Tester::Hub->synergize({
    state_dbfile => ':memory:',
    channels => {
      ($arg->{extra_channels} // {})->%*,
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
        default_from => $arg->{default_from} // 'tester',
      },
    },
    reactors => $arg->{reactors},
    server_port => empty_port(),
    metrics_path => '/metrics',

    defined_kv(tls_cert_file => $arg->{tls_cert_file}),
    defined_kv(tls_key_file  => $arg->{tls_key_file}),
  });

  my $users = $arg->{users};
  my $directory = $synergy->user_directory;

  for my $username (keys %$users) {
    my $config = $users->{$username} // {};

    my $user = Synergy::User->new({
      username   => $username,
      directory  => $directory,
      identities => {
        ($config->{extra_identities} ? $config->{extra_identities}->%* : ()),
        'test-channel' => $username,
      },
    });

    $directory->register_user($user);
  }

  return wantarray ? ($synergy, $Logger) : $synergy;
}

1;
