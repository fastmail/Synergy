use v5.24.0;
use warnings;
package Synergy::Role::HasDatabaseHandle;

use Moose::Role;

use experimental qw(signatures lexical_subs);
use namespace::clean;

has dbfile => (
  is  => 'ro',
  isa => 'Str',
  lazy => 1,
  default => "synergy.sqlite",
);

has dbh => (
  is  => 'ro',
  init_arg => undef,
  lazy => 1,
  default  => sub ($self, @) {
    # NOTE: I am making this a singleton now, because it was (effectively)
    # before, but we might reconsider that. -- michael, 2020-03-04
    state $dbh;
    return $dbh if $dbh;

    my $dbf = $self->dbfile;

    $dbh = DBI->connect(
      "dbi:SQLite:dbname=$dbf",
      undef,
      undef,
      { RaiseError => 1 },
    );

    unless ($dbh) {
      no warnings 'once';
      die $DBI::errstr;
    }

    $self->_maybe_create_tables($dbh);

    return $dbh;
  },
);

sub _maybe_create_tables ($self, $dbh) {
  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS synergy_state (
      reactor_name TEXT PRIMARY KEY,
      stored_at INTEGER NOT NULL,
      json TEXT NOT NULL
    );
  });

  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS users (
      username TEXT PRIMARY KEY,
      lp_id TEXT,
      is_master INTEGER DEFAULT 0,
      is_virtual INTEGER DEFAULT 0,
      is_deleted INTEGER DEFAULT 0
    );
  });

  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS user_identities (
      id INTEGER PRIMARY KEY,
      username TEXT NOT NULL,
      identity_name TEXT NOT NULL,
      identity_value TEXT NOT NULL,
      FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE,
      CONSTRAINT constraint_username_identity UNIQUE (username, identity_name),
      UNIQUE (identity_name, identity_value)
    );
  });
}

1;
