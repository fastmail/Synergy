use v5.24.0;
use warnings;
package Synergy::Rototron;

use charnames qw( :full );

use DateTime ();

use JMAP::Tester;

package Synergy::Rototron::Rotor {
  use Moose;
  use experimental qw(lexical_subs signatures);

  my sub flag ($str) {
    join q{},
    map {; charnames::string_vianame("REGIONAL INDICATOR SYMBOL LETTER $_") }
    split //, uc $str;
  }

  my %substitutions = (
    'flag-au'   => flag('au'),
    'flag-us'   => flag('us'),
    'sparkles'  => "\N{SPARKLES}",
  );

  has name => (is => 'ro', required => 1);

  has raw_description => (
    is => 'ro',
    required => 1,
    init_arg => 'description',
  );

  has description => (
    is   => 'ro',
    lazy => 1,
    init_arg  => undef,
    default   => sub ($self, @) {
      my $desc = $self->raw_description;
      $desc =~ s/:$_:/$substitutions{$_}/g for keys %substitutions;
      return $desc;
    },
  );

  has _staff_filter => (
    is       => 'ro',
    init_arg => 'staff',
    required => 1,
  );

  has _full_staff => (
    is       => 'ro',
    init_arg => 'full_staff',
    required => 1,
  );

  has _staff => (
    is       => 'ro',
    lazy     => 1,
    init_arg => undef,
    default  => sub ($self, @) {
      my @staff = $self->_full_staff->@*;
      return [@staff] unless my $filter = $self->_staff_filter;

      @staff = grep {;
        (! $filter->{region} or $_->{region} eq $filter->{region})
        &&
        (! $filter->{team}   or $_->{team}   eq $filter->{team})
      } @staff;

      return [@staff];
    },
  );

  has calendar_id => (is => 'ro', required => 1);

  has _excluded_dow => (
    is  => 'ro',
    init_arg  => 'exclude_dow',
    default   => sub {  []  },
  );

  sub excludes_dow ($self, $dow) {
    return scalar grep {; $dow == $_ } $self->_excluded_dow->@*;
  }

  sub keyword ($self) {
    return join q{:}, 'rotor', $self->name;
  }

  has availability_checker => (
    is => 'ro',
    required => 1,
    handles  => [ qw( user_is_available_on ) ],
  );

  # Let's talk about the epoch here.  It's the first Monday before this program
  # existed.  To compute who handles what in a given week, we compute the week
  # number, with this week as week zero.  Everything else is a rotation through
  # that.
  #
  # We may very well change this later. -- rjbs, 2019-01-30
  my $epoch = 1548633600;

  my sub _week_of_date ($dt) { int( ($dt->epoch - $epoch) / (86400 * 7) ) }

  sub user_for_day ($self, $day) {
    my @staff = $self->_staff->@*;

    my $weekn = _week_of_date($day);

    while (@staff) {
      my $user = splice @staff, $weekn % @staff, 1;
      return $user if $self->user_is_available_on($user->{username}, $day);
    }

    return undef;
  }

  no Moose;
}

package Synergy::Rototron::AvailabilityChecker {
  use Moose;
  use experimental qw(lexical_subs signatures);

  use DBD::SQLite;

  has db_path => (
    is  => 'ro',
    required => 1,
  );

  has _dbh => (
    is  => 'ro',
    lazy => 1,
    default => sub ($self, @) {
      my $path = $self->db_path;
      Carp::confess("db path does not exist") unless -e $path;
      my $dbh = DBI->connect("dbi:SQLite:$path", undef, undef)
        or die "can't connect to db at $path: $DBI::errstr";

      return $dbh;
    },
  );

  sub user_is_available_on ($self, $username, $dt) {
    my ($count) = $self->_dbh->selectrow_array(
      q{SELECT COUNT(*) FROM blocked_days WHERE username = ? AND date = ?},
      undef,
      $username,
      $dt->ymd,
    );

    return $count == 0;
  }

  sub set_user_unavailable_on ($self, $username, $dt, $reason = undef) {
    my $ok = $self->_dbh->do(
      q{
        INSERT OR REPLACE INTO blocked_days (username, date, reason)
        VALUES (?, ?, ?)
      },
      undef,
      $username,
      $dt->ymd,
      $reason,
    );

    return $ok;
  }

  sub set_user_available_on ($self, $username, $dt) {
    my $ok = $self->_dbh->do(
      q{
        DELETE FROM blocked_days
        WHERE username = ? AND date = ?
      },
      undef,
      $username,
      $dt->ymd,
    );

    return $ok;
  }

  no Moose;
}

package Synergy::Rototron::JMAPClient {
  use Moose;
  use experimental qw(lexical_subs signatures);

  extends 'JMAP::Tester';
  has [ qw(username password) ] => (is => 'ro', required => 1);

  use MIME::Base64 ();

  sub _maybe_auth_header ($self, @) {
    my $auth = MIME::Base64::encode_base64(
      join(q{:}, $self->username, $self->password),
      ""
    );
    return("Authorization" => "Basic $auth");
  }

  no Moose;
}

1;
