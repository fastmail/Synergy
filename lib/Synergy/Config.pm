use v5.24.0;
use warnings;
package Synergy::Config;

use Moose;
use experimental qw(signatures);

has name => (
  is  => 'ro',
  isa => 'Str',
  default => 'Synergy',
);

has time_zone_names => (
  is  => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

has state_dbfile => (
  is  => 'ro',
  isa => 'Str',
  lazy => 1,
  default => "synergy.sqlite",
);

has server_port => (
  is => 'ro',
  isa => 'Int',
  default => 8118,
);

has tls_cert_file => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has tls_key_file => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has user_directory_file => (
  is => 'ro',
  isa => 'Str',
  init_arg => 'user_directory',
  predicate => 'has_user_directory_file',
);

for my $thing (qw( channel reactor )) {
  my $plural = "${thing}s";

  has "${thing}_config" => (
    is       => 'ro',
    isa      => 'HashRef',
    traits   => ['Hash'],
    init_arg => $plural,
    handles  => {
      "${thing}_names"    => 'keys',
      "config_for_$thing" => 'get',
    },
  );
}

# $thing_type is 'channel' or 'reactor'
sub component_names_for ($self, $thing_type) {
  my $method = "${thing_type}_names";
  return $self->$method;
}

sub component_config_for ($self, $thing_type, $name) {
  my $method = "config_for_${thing_type}";
  return $self->$method($name);
}

has state_dbh => (
  is  => 'ro',
  init_arg => undef,
  lazy => 1,
  default  => sub ($self, @) {
    # NOTE: I am making this a singleton now, because it was (effectively)
    # before, but we might reconsider that. -- michael, 2020-03-04
    state $dbh;
    return $dbh if $dbh;

    my $dbf = $self->state_dbfile;

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
