use v5.24.0;
use warnings;
package Synergy::Role::ManagesState;

use Moose::Role;

use experimental qw(signatures lexical_subs);
use namespace::clean;

use JSON::MaybeXS;
use Synergy::Logger '$Logger';

requires 'dbh';

sub save_state ($self, $namespace, $state) {
  my $json = eval { JSON::MaybeXS->new->utf8->encode($state) };

  unless ($json) {
    $Logger->log([ "error serializing state for %s: %s", $namespace, $@ ]);
    return;
  }

  $self->dbh->do(
    "INSERT OR REPLACE INTO synergy_state (reactor_name, stored_at, json)
    VALUES (?, ?, ?)",
    undef,
    $namespace,
    time,
    $json,
  );

  return 1;
}

sub fetch_state ($self, $namespace) {
  my ($json) = $self->dbh->selectrow_array(
    "SELECT json FROM synergy_state WHERE reactor_name = ?",
    undef,
    $namespace,
  );

  return unless $json;
  return JSON::MaybeXS->new->utf8->decode($json);
}

1;
