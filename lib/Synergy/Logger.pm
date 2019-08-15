use strict;
use warnings;
package Synergy::Logger;
use parent 'Log::Dispatchouli::Global';

use Log::Dispatchouli 2.019; # enable_stderr

sub logger_globref {
  no warnings 'once';
  \*Logger;
}

sub default_logger_class { 'Synergy::Logger::_Logger' }

sub default_logger_args {
  return {
    ident     => "synergy",
    facility  => 'daemon',
    to_stderr => $_[0]->default_logger_class->env_value('STDERR') ? 1 : 0,
  }
}

{
  package Synergy::Logger::_Logger;
  use parent 'Log::Dispatchouli';

  sub env_prefix { 'SYNERGY_LOG' }
}

1;

