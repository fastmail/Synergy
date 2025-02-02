use strict;
package Synergy::Logger::Test;

use parent 'Synergy::Logger';

use Synergy::Logger '$Logger' => {
  init => {
    ident     => "test-synergy",
    to_self   => 1,
    facility  => undef,
    log_pid   => 0,
    to_stderr => !! Synergy::Logger->default_logger_class->env_value('STDERR'),
    to_tap    => !! Synergy::Logger->default_logger_class->env_value('TAP'),
  },
};

1;
