package Synergy::Test::EmptyPort;
use strict;
use warnings;

use experimental qw(signatures);

use Net::EmptyPort ();

use Sub::Exporter -setup => [ qw(empty_port) ];

sub empty_port () {
  if ($ENV{GITHUB_ACTIONS}) {
    return 60606;
  }

  return Net::EmptyPort::empty_port();
}

1;
