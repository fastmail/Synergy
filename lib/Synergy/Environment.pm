use v5.24.0;
use warnings;
package Synergy::Environment;

use Moose;
use experimental qw(signatures);

sub BUILD ($self, @) {
  $self->_maybe_create_state_tables;

  $self->user_directory->load_users_from_database;

  if ($self->has_user_directory_file) {
    $self->user_directory->load_users_from_file($self->user_directory_file);
  }
}

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
  init_arg => 'user_directory',   # backcompat
  predicate => 'has_user_directory_file',
);

has user_directory => (
  is => 'ro',
  isa => 'Synergy::UserDirectory',
  lazy => 1,
  init_arg => undef,
  default => sub ($self) {
    require Synergy::UserDirectory;
    Synergy::UserDirectory->new({ env => $self });
  },
);

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

    return $dbh;
  },
);

sub _maybe_create_state_tables ($self) {
  $self->state_dbh->do(q{
    CREATE TABLE IF NOT EXISTS synergy_state (
      reactor_name TEXT PRIMARY KEY,
      stored_at INTEGER NOT NULL,
      json TEXT NOT NULL
    );
  });

  $self->state_dbh->do(q{
    CREATE TABLE IF NOT EXISTS users (
      username TEXT PRIMARY KEY,
      lp_id TEXT,
      is_master INTEGER DEFAULT 0,
      is_virtual INTEGER DEFAULT 0,
      is_deleted INTEGER DEFAULT 0
    );
  });

  $self->state_dbh->do(q{
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

sub format_friendly_date ($self, $dt, $arg = {}) {
  # arg:
  #   now               - a DateTime to use for now, instead of actually now
  #   allow_relative    - can we use relative stuff? default true
  #   include_time_zone - default true
  #   maybe_omit_day    - default false; if true, skip "today at" on today
  #   target_time_zone  - format into this time zone; default, $dt's TZ

  if ($arg->{target_time_zone} && $arg->{target_time_zone} ne $dt->time_zone->name) {
    $dt = DateTime->from_epoch(
      time_zone => $arg->{target_time_zone},
      epoch => $dt->epoch,
    );
  }

  my $now = $arg->{now}
          ? $arg->{now}->clone->set_time_zone($dt->time_zone)
          : DateTime->now(time_zone => $dt->time_zone);

  my $dur = $now->subtract_datetime($dt);
  my $tz_str = $self->time_zone_names->{ $dt->time_zone->name }
            // $dt->format_cldr('vvv');

  my $at_time = "at "
              . $dt->format_cldr('HH:mm')
              . (($arg->{include_time_zone}//1) ? " $tz_str" : "");

  if (abs($dur->delta_months) > 11) {
    return $dt->format_cldr('MMMM d, YYYY') . " $at_time";
  }

  if ($dur->delta_months) {
    return $dt->format_cldr('MMMM d') . " $at_time";
  }

  my $days = $dur->delta_days;

  if (abs $days >= 7 or ! ($arg->{allow_relative}//1)) {
    return $dt->format_cldr('MMMM d') . " $at_time";
  }

  my %by_day = (
    -2 => "the day before yesterday $at_time",
    -1 => "yesterday $at_time",
    +0 => "today $at_time",
    +1 => "tomorrow $at_time",
    +2 => "the day after tomorrow $at_time",
  );

  for my $offset (sort { $a <=> $b } keys %by_day) {
    return $by_day{$offset}
      if $dt->ymd eq $now->clone->add(days => $offset)->ymd;
  }

  my $which = $dur->is_positive ? "this past" : "this coming";
  return join q{ }, $which, $dt->format_cldr('EEEE'), $at_time;
}

1;
