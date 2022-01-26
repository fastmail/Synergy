use v5.28.0;
use warnings;
package Synergy::Rototron;

use Moose;
use experimental qw(lexical_subs signatures);

use charnames qw( :full );

use Data::GUID qw(guid_string);
use DateTime ();
use File::stat;
use JMAP::Tester;
use Params::Util qw(_HASH0);
use Synergy::Util qw(read_config_file);

my $PROGRAM_ID = 'Synergy::Rototron/20190131.001';

has config_path => (
  is => 'ro',
  required => 1,
);

has _cached_config => (
  is => 'ro',
  lazy     => 1,
  init_arg => undef,
  default  => sub {  {}  },
);

sub config ($self) {
  my $cached = $self->_cached_config;

  my $path = $self->config_path;
  my $stat = stat $path;
  my @fields = qw(dev ino mtime);

  if ($cached && $cached->{mtime}) {
    return $cached->{config}
      if @fields == grep { $cached->{$_} == $stat->$_ } @fields;
  }

  my $config = read_config_file($path);

  %$cached = map {; $_ => $stat->$_ } @fields;
  $cached->{config} = $config;

  $self->_clear_availability_checker;
  $self->_clear_jmap_client;
  $self->_clear_rotors;

  return $cached->{config}
}

my @USING = qw(
  urn:ietf:params:jmap:core
  urn:ietf:params:jmap:mail
  urn:ietf:params:jmap:submission
  https://cyrusimap.org/ns/jmap/mail
  https://cyrusimap.org/ns/jmap/contacts
  https://cyrusimap.org/ns/jmap/calendars
);

has availability_checker => (
  is    => 'ro',
  lazy  => 1,
  handles  => [ qw( user_is_available_on ) ],
  clearer  => '_clear_availability_checker',
  default  => sub ($self, @) {
    Synergy::Rototron::AvailabilityChecker->new({
      db_path => $self->config->{availability_db},
      calendars => $self->config->{availability_calendars},
      user_directory => $self->user_directory,

      # XXX This is bonkers. -- rjbs, 2019-02-02
      jmap_client => Synergy::Rototron::JMAPClient->new({
        default_using => \@USING,
        $self->config->{jmap}->%{ qw( api_uri username password ) },
      }),
    });
  }
);

has user_directory => (
  is => 'ro',
  required => 1,
  isa => 'Synergy::UserDirectory',
);

has jmap_client => (
  is    => 'ro',
  lazy  => 1,
  clearer => '_clear_jmap_client',
  default => sub ($self, @) {
    return Synergy::Rototron::JMAPClient->new({
      default_using => \@USING,
      $self->config->{jmap}->%{ qw( api_uri username password ) },
    });
  },
);

has rotors => (
  lazy  => 1,
  traits  => [ qw(Array) ],
  handles => { rotors => 'elements' },
  clearer => '_clear_rotors',
  default => sub ($self, @) {
    my $config = $self->config;

    my @rotors;
    for my $key (keys $config->{rotors}->%*) {
      push @rotors, Synergy::Rototron::Rotor->new({
        $config->{rotors}{$key}->%*,
        name        => $key,
        full_staff  => $config->{staff},
        availability_checker => $self->availability_checker,
      });
    }

    \@rotors;
  },
);

has _duty_cache => (
  is      => 'ro',
  lazy    => 1,
  default => sub {  {}  },
);

sub duties_on ($self, $dt) {
  my $ymd = $dt->ymd;

  my $cached = $self->_duty_cache->{$ymd};

  if (! $cached || (time - $cached->{at} > 900)) {
    my $items = $self->_get_duty_items_between($ymd, $ymd);
    return unless $items; # Error.

    $cached->{$ymd} = {
      at    => time,
      items => $items,
    };
  }

  return $cached->{$ymd}{items};
}

sub _get_duty_items_between ($self, $from_ymd, $to_ymd) {
  my %want_calendar_id = map {; $_->{calendar_id} => 1 } $self->rotors;

  my $from = $from_ymd =~ /Z\z/ ? $from_ymd : "${from_ymd}T00:00:00Z";
  my $to   = $to_ymd   =~ /Z\z/ ? $to_ymd   : "${to_ymd}T00:00:00Z";

  my $res = eval {
    my $res = $self->jmap_client->request({
      using       => [ 'urn:ietf:params:jmap:mail', 'https://cyrusimap.org/ns/jmap/calendars', ],
      methodCalls => [
        [
          'CalendarEvent/query' => {
            filter => {
              inCalendars => [ keys %want_calendar_id ],
              after       => $from,
              before      => $to,
            },
          },
          'a',
        ],
        [
          'CalendarEvent/get' => { '#ids' => {
            resultOf => 'a',
            name => 'CalendarEvent/query',
            path => '/ids',
          } }
        ],
      ]
    });

    $res->assert_successful;
    $res;
  };

  # Error condition. -- rjbs, 2019-01-31
  return undef unless $res;

  my @events =
    grep {; $want_calendar_id{ $_->{calendarId} } }
    $res->sentence_named('CalendarEvent/get')->as_stripped_pair->[1]{list}->@*;

  return \@events;
}

my sub event_mismatches ($lhs, $rhs) {
  my %mismatch;

  for my $key (qw(
    @type title start duration showWithoutTime freeBusyStatus keywords
  )) {
    $mismatch{$key} = 1
      if (defined $lhs->{$key} xor defined $rhs->{$key})
      || (_HASH0 $lhs->{$key} xor _HASH0 $rhs->{$key})
      || (_HASH0 $lhs->{$key} && join(qq{\0}, sort keys $lhs->{$key}->%*)
                              ne join(qq{\0}, sort keys $rhs->{$key}->%*))
      || (! _HASH0 $lhs->{$key}
          && defined $lhs->{$key}
          && $lhs->{$key} ne $rhs->{$key});
  }

  if (0) {
    # This isn't great.  I want this to be here, but I also need to be able to
    # remove all participants from events with them.  Looks like I can't set
    # participants to undef or {} and I'm not sure how to proceed.  So we can
    # ignore this for now. -- rjbs, 2021-04-30
    my $lhs_p = exists $lhs->{participants} ? keys $lhs->{participants}->%* : 0;
    my $rhs_p = exists $rhs->{participants} ? keys $rhs->{participants}->%* : 0;
    $mismatch{participants} = 1 if $lhs_p != $rhs_p;
  }

  return sort keys %mismatch;
}

sub compute_rotor_update ($self, $from_dt, $to_dt) {
  my %want;

  for my $rotor ($self->rotors) {
    for (my $day = $from_dt->clone; $day <= $to_dt; $day->add(days => 1)) {
      next if $rotor->excludes_dow($day->day_of_week);

      my $user  = $rotor->user_for_day($day, $rotor);
      my $name  = $user ? ($user->{name} // $user->{username}) : '(nobody)';

      # TODO: never change the assignee of the current week when we change
      # rotations, but... this can wait -- rjbs, 2019-01-30

      my $start = $day->ymd . "T00:00:00";

      $want{ $rotor->keyword }{ $start } = {
        '@type'   => 'jsevent',
        prodId    => "$PROGRAM_ID",
        title     => join(q{ - }, $rotor->description, $name),
        start     => $start,
        duration  => "P1D",
        keywords  => {
          $rotor->keyword => JSON::MaybeXS->true,
          ($user  ? ("username:" . $user->{username} => JSON::MaybeXS->true)
                  : ()),
        },
        calendarId      => $rotor->calendar_id,
        freeBusyStatus  => "free",
        showWithoutTime => JSON::MaybeXS->true,
      }
    };
  }

  my %want_calendar_id = map {; $_->calendar_id => 1 } $self->rotors;

  my $events = $self->_get_duty_items_between($from_dt->ymd, $to_dt->ymd);
  Carp::confess("failed to get events") unless $events;

  my %saw;

  my %update;
  my %create;
  my %should_destroy;

  for my $event (@$events) {
    my ($rtag, @more) = grep {; /\Arotor:/ } keys %{ $event->{keywords} || {} };

    unless ($rtag) {
      # warn "skipping event with no rotor keywords: $event->{id}\n";
      next;
    }

    if (@more) {
      # warn "skipping event with multiple rotor keywords: $event->{id}\n";
      next;
    }

    if ($saw{$rtag}{ $event->{start} }++) {
      # warn "found duplicate event for $rtag on $event->{start}; skipping some\n";
      next;
    }

    my $wanted = delete $want{$rtag}{ $event->{start} };

    # If event isn't on the want list, plan a destroy.
    if (! $wanted) {
      # warn "marking unwanted event $event->{id} for deletion\n";
      $should_destroy{ $event->{id} } = 1;
      next;
    }

    my @mismatches = event_mismatches($event, $wanted);

    # If event is different than wanted, delete from %want and plan an update.
    if (@mismatches) {
      # warn "updating event $event->{id} to align fields: @mismatches\n";
      $update{ $event->{id} } = $wanted;
      next;
    }

    # If event is equivalent to wanted, delete from %want and do nothing.
  }

  for my $rtag (sort keys %want) {
    for my $start (sort keys $want{$rtag}->%*) {
      $create{"$rtag/$start"} = $want{$rtag}{$start};
      $create{"$rtag/$start"}{uid} = lc guid_string;
    }
  }

  return unless %update or %create or %should_destroy;

  return {
    update  => \%update,
    create  => \%create,
    destroy => [ keys %should_destroy ],
  }
}

package Synergy::Rototron::Rotor {
  use Moose;
  use experimental qw(lexical_subs signatures);

  use Synergy::Logger '$Logger';

  my sub flag ($str) {
    join q{},
    map {; charnames::string_vianame("REGIONAL INDICATOR SYMBOL LETTER $_") }
    split //, uc $str;
  }

  my %substitutions = (
    'flag-au'   => flag('au'),
    'flag-us'   => flag('us'),
    'sparkles'  => "\N{SPARKLES}",
    'helmet'    => "\N{HELMET WITH WHITE CROSS}",
    'wrench'    => "\N{WRENCH}",
    'frame_with_picture' => "\N{FRAME WITH PICTURE}",
  );

  has name => (is => 'ro', required => 1);
  has time_zone => (is => 'ro');

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

      my $name = $self->name;

      @staff = grep {;
        (! $filter->{region} or $_->{region} eq $filter->{region})
        &&
        (! $filter->{team}   or (grep { $_ eq $filter->{team} } $_->{teams}->@*))
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
    handles  => [ qw(
      manual_assignment_for
      update_manual_assignments
      user_is_available_on
    ) ],
  );

  # Let's talk about the epoch here.  It's the first Monday before this program
  # existed.  To compute who handles what in a given week, we compute the week
  # number, with this week as week zero.  Everything else is a rotation through
  # that.
  #
  # We may very well change this later. -- rjbs, 2019-01-30
  my $epoch = 1548633600;

  my sub _week_of_date ($dt) { int( ($dt->epoch - $epoch) / (86400 * 7) ) }

  sub user_for_day ($self, $day, $rotor) {
    my @staff = $self->_staff->@*;

    if (my $username = $self->manual_assignment_for($rotor, $day)) {
      my ($user) = grep {; $_->{username} eq $username } $self->_full_staff->@*;
      return $user if $user;

      $Logger->log([
        "no user named %s, but that name is assigned for %s on %s",
        $username,
        $rotor->name,
        $day->ymd,
      ]);
    }

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
      my $dbh = DBI->connect("dbi:SQLite:$path", undef, undef, { RaiseError => 1 })
        or die "can't connect to db at $path: $DBI::errstr";

      return $dbh;
    },
  );

  has user_directory => (
    is => 'ro',
    required => 1,
  );

  has jmap_client => (
    is => 'ro',
    required => 1,
  );

  has calendars => (
    required  => 1,
    traits    => [ 'Array' ],
    handles   => { calendars => 'elements' },
  );

  has _calevent_cache => (
    is => 'ro',
    default   => sub {  {}  },
  );

  sub _leave_days ($self) {
    my $cache = $self->_calevent_cache;
    return $cache->{leave_days}
      if $cache->{cached_at} && (time - $cache->{cached_at} < 900);

    my @calendars = $self->calendars;

    my %leave_days;

    CALENDAR: for my $calendar ($self->calendars) {
      my $res = eval {
        my $res = $self->jmap_client->request({
          using       => [ 'urn:ietf:params:jmap:mail', 'https://cyrusimap.org/ns/jmap/calendars', ],
          methodCalls => [
            [
              'CalendarEvent/query' => {
                accountId   => $calendar->{accountId},
                filter => {
                  inCalendars => [ $calendar->{calendarId} ],
                  after       => DateTime->now->ymd . "T00:00:00Z", # endAfter
                },
              },
              'a',
            ],
            [
              'CalendarEvent/get' => {
                accountId   => $calendar->{accountId},
                '#ids' => {
                  resultOf => 'a',
                  name => 'CalendarEvent/query',
                  path => '/ids',
                }
              }
            ],
          ]
        });

        $res->assert_successful;
        $res;
      };

      # Error condition. -- rjbs, 2019-01-31
      next CALENDAR unless $res;

      my @events = $res->sentence_named('CalendarEvent/get')
                       ->as_stripped_pair->[1]{list}->@*;

      EVENT: for my $event (@events) {
        my (@who) = map {; /^username:(\S+)\z/ ? $1 : () }
                    keys $event->{keywords}->%*;

        unless (@who) {
          warn "skipping event with no usernames ($event->{id} - $event->{start} - $event->{title})\n";
          next EVENT;
        }

        my $days;

        if (($event->{duration} // '') =~ /\AP([0-9]+)D\z/) {
          $days = $1;
        } elsif (($event->{duration} // '') =~ /\AP([0-9]+)W\z/) {
          $days = 7 * $1;
        }

        unless ($days) {
          warn "skipping event with wonky duration ($event->{id} - $event->{start} - $event->{title} - $event->{duration})\n";
          next EVENT;
        }

        $days-- if $days;

        my ($start) = split /T/, $event->{start};
        my ($y, $m, $d) = split /-/, $start;
        my $curr = DateTime->new(year => $y, month => $m, day => $d);

        for (0 .. $days) {
          $leave_days{ $_ }{ $curr->ymd } = 1 for @who;
          $curr->add(days => 1);
        }
      }
    }

    %$cache = (cached_at => time, leave_days => \%leave_days);
    return \%leave_days;
  }

  sub manual_assignment_for ($self, $rotor, $day) {
    my $ymd = $day->ymd;

    my ($username) = $self->_dbh->selectrow_array(
      q{SELECT username FROM manual_assignments WHERE rotor_name = ? AND date = ?},
      undef,
      $rotor->name,
      $ymd,
    );

    return $username;
  }

  # update_manual_assignments({
  #   rotor1 => {
  #     ymd1 => user1,
  #     ymd2 => user1,
  #     ymd3 => undef,
  #   },
  #   ...
  sub update_manual_assignments ($self, $plan) {
    my $dbh = $self->_dbh;

    $dbh->begin_work;

    # We don't know the users or rotors here, so it better be valid.
    # -- rjbs, 2019-11-13
    for my $rotor (keys %$plan) {
      for my $ymd (keys $plan->{$rotor}->%*) {
        # validate ymd? -- rjbs, 2019-11-13
        $dbh->do(
          "DELETE FROM manual_assignments WHERE rotor_name = ? AND date = ?",
          undef,
          $rotor,
          $ymd,
        );

        my $username = $plan->{$rotor}{$ymd};
        if (defined $username) {
          $dbh->do(
            "INSERT INTO manual_assignments (rotor_name, date, username) VALUES (?,?,?)",
            undef,
            $rotor,
            $ymd,
            $username,
          );
        }
      }
    }

    $dbh->commit;

    return;
  }

  sub user_is_available_on ($self, $username, $dt) {
    my $ymd = $dt->ymd;

    if (my $user = $self->user_directory->user_named($username)) {
      return 0 unless $user->hours_for_dow($dt->day_of_week);
    }

    my $leave = $self->_leave_days;
    return 0 if $leave->{$username}{$dt->ymd};

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

no Moose;
1;
