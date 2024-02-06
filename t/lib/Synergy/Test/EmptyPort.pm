package Synergy::Test::EmptyPort;
use strict;
use warnings;

use experimental qw(signatures);

use Net::EmptyPort ();

use Sub::Exporter -setup => [ qw(empty_port) ];

sub empty_port () {
  return Net::EmptyPort::empty_port();
}

1;
