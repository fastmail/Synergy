use strict;
use warnings;
package Synergy::Logger::Test;
use parent 'Synergy::Logger';

use Synergy::Logger '$Logger' => {
  init => {
    ident     => "test-synergy",
    to_self   => 1,
    facility  => undef,
    to_stderr => !! Synergy::Logger->default_logger_class->env_value('STDERR')
  },
};

1;
