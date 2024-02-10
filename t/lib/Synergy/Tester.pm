#!perl
use v5.32.0;
use warnings;

package Synergy::Tester;

use experimental 'signatures';

use Synergy::Logger::Test '$Logger';

use Defined::KV;
use IO::Async::Test;
use Net::EmptyPort qw(empty_port);
use Synergy::Hub;

package Synergy::Tester::Result {
  use Moose;

  has synergy => (is => 'ro');
  has logger  => (is => 'ro');

  no Moose;
  __PACKAGE__->meta->make_immutable;
}

sub _test_logger {
  Synergy::Logger->default_logger_class->new({
    ident     => "synergy-tester",
    to_self   => 1,
    facility  => undef,
    log_pid   => 0,
    to_stderr => !! Synergy::Logger->default_logger_class->env_value('STDERR'),
    to_tap    => !! Synergy::Logger->default_logger_class->env_value('TAP'),
  });
}

sub testergize {
  my ($class, $arg) = @_;

  local $Logger = $class->_test_logger;

  my $synergy = Synergy::Hub->synergize(
    {
      state_dbfile => ':memory:',
      channels => {
        'test-channel' => {
          class     => 'Synergy::Channel::Test',
          default_from => $arg->{default_from} // 'tester',
        },
        ($arg->{extra_channels} // {})->%*,
      },
      reactors => $arg->{reactors},
      server_port => empty_port(),
      metrics_path => '/metrics',

      defined_kv(tls_cert_file => $arg->{tls_cert_file}),
      defined_kv(tls_key_file  => $arg->{tls_key_file}),
    }
  );

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

  return $class->test_synergy($synergy, $arg->{todo}, { logger => $Logger });
}

sub test_synergy ($class, $synergy, $todo, $arg = {}) {
  local $Logger = $arg->{logger} // $class->_test_logger;

  $synergy->channel_named('test-channel')->queue_todo($_) for $todo->@*;

  testing_loop($synergy->loop);

  wait_for {
    return unless $synergy->channel_named('test-channel')->is_exhausted;

    my @events = grep {; ! $_->{event}->completeness->is_ready }
                 $synergy->_events_in_flight;

    return if @events;

    return 1;
  };

  return Synergy::Tester::Result->new({
    synergy => $synergy,
    logger  => $Logger,
  });
}

1;
