use v5.24.0;
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

  my $config = do {
    open my $fh, '<', $path or die "can't read $path: $!";
    my $json = do { local $/; <$fh> };
    JSON::MaybeXS->new->utf8(1)->decode($json);
  };

  %$cached = map {; $_ => $stat->$_ } @fields;
  $cached->{config} = $config;

  $self->_clear_availability_checker;
  $self->_clear_jmap_client;
  $self->_clear_rotors;

  return $cached->{config}
}

has availability_checker => (
  is    => 'ro',
  lazy  => 1,
  handles  => [ qw( user_is_available_on ) ],
  clearer  => '_clear_availability_checker',
  default  => sub ($self, @) {
    Synergy::Rototron::AvailabilityChecker->new({
      db_path => $self->config->{availability_db},
      calendars => $self->config->{availability_calendars},

      # XXX This is bonkers. -- rjbs, 2019-02-02
      jmap_client => Synergy::Rototron::JMAPClient->new({
        $self->config->{jmap}->%{ qw( api_uri username password ) },
      }),
    });
  }
);

has jmap_client => (
  is    => 'ro',
  lazy  => 1,
  clearer => '_clear_jmap_client',
  default => sub ($self, @) {
    return Synergy::Rototron::JMAPClient->new({
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

  my $res = eval {
    my $res = $self->jmap_client->request({
      using       => [ 'urn:ietf:params:jmap:mail' ],
      methodCalls => [
        [
          'CalendarEvent/query' => {
            filter => {
              inCalendars => [ keys %want_calendar_id ],
              after       => $from_ymd . "T00:00:00Z",
              before      => $to_ymd . "T00:00:00Z",
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
    @type title start duration isAllDay freeBusyStatus
    replyTo keywords
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

  $mismatch{participants} = 1
    if keys $lhs->{participants}->%* != keys $rhs->{participants}->%*;

  $mismatch{participants} = 1
    if grep { ! exists $rhs->{participants}{$_} } keys $lhs->{participants}->%*;

  for my $pid (keys $lhs->{participants}->%*) {
    my $lhsp = $lhs->{participants}->{$pid};
    my $rhsp = $rhs->{participants}->{$pid};

    for my $key (qw( name email kind roles participationStatus )) {
      $mismatch{"participants.$pid.$key"} = 1
        if (defined $lhsp->{$key} xor defined $rhsp->{$key})
        || (_HASH0 $lhsp->{$key} xor _HASH0 $rhsp->{$key})
        || (_HASH0 $lhsp->{$key} && join(qq{\0}, sort keys $lhsp->{$key}->%*)
                                ne join(qq{\0}, sort keys $rhsp->{$key}->%*))
        || (! _HASH0 $lhsp->{$key}
            && defined $lhsp->{$key}
            && $lhsp->{$key} ne $rhsp->{$key});
    }
  }

  return sort keys %mismatch;
}

sub compute_rotor_update ($self, $from_dt, $to_dt) {
  my %want;

  for my $rotor ($self->rotors) {
    for (my $day = $from_dt->clone; $day <= $to_dt; $day->add(days => 1)) {
      next if $rotor->excludes_dow($day->day_of_week);

      my $user  = $rotor->user_for_day($day);

      # TODO: never change the assignee of the current week when we change
      # rotations, but... this can wait -- rjbs, 2019-01-30

      my $start = $day->ymd . "T00:00:00";

      $want{ $rotor->keyword }{ $start } = {
        '@type'   => 'jsevent',
        prodId    => "$PROGRAM_ID",
        title     => join(q{ - },
                      $rotor->description,
                      $user->{name} // $user->{username}),
        start     => $start,
        duration  => "P1D",
        isAllDay  => JSON::MaybeXS->true,
        keywords  => { $rotor->keyword => JSON::MaybeXS->true },
        replyTo   => { imip => "MAILTO:$user->{username}\@fastmailteam.com" },
        freeBusyStatus  => "free",
        calendarId      => $rotor->calendar_id,
        participants    => {
          $user->{username} => {
            participationStatus => 'accepted',
            name  => $user->{name} // $user->{username},
            email => "$user->{username}\@fastmailteam.com",
            kind  => "individual",
            roles => {
              # XXX: I don't think "owner" is correct, here, but if I don't put
              # it in the event definition, it gets added anyway, and then when
              # we run a second time, we detect a difference between plan and
              # found, and update the event, fruitlessly hoping that the
              # participant roles will be right this time.  Bah.
              # -- rjbs, 2019-01-30
              owner    => JSON::MaybeXS->true,

              attendee => JSON::MaybeXS->true,
            },
          },
        }
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

    die "only one calendar for now" if @calendars > 1;
    return [] unless @calendars;

    my $res = eval {
      my $res = $self->jmap_client->request({
        using       => [ 'urn:ietf:params:jmap:mail' ],
        methodCalls => [
          [
            'CalendarEvent/query' => {
              accountId   => $calendars[0]{accountId},
              filter => {
                inCalendars => [ $calendars[0]{calendarId} ],
                after       => DateTime->now->ymd . "T00:00:00Z", # endAfter
              },
            },
            'a',
          ],
          [
            'CalendarEvent/get' => {
              accountId   => $calendars[0]{accountId},
              '#ids' => {
                resultOf => 'a',
                name => 'CalendarEvent/query',
                path => '/ids',
              }
            }
          ],
        ]
      });

      $res;
    };

    # Error condition. -- rjbs, 2019-01-31
    return undef unless $res;

    my @events = $res->sentence_named('CalendarEvent/get')
                     ->as_stripped_pair->[1]{list}->@*;

    my %leave_days;

    EVENT: for my $event (@events) {
      my (@who) = map {; /^username:(\S+)\z/ ? $1 : () }
                  keys $event->{keywords}->%*;

      unless (@who) {
        warn "skipping event with no usernames\n";
        next EVENT;
      }

      my ($days) = ($event->{duration} // '') =~ /\AP([0-9]+)D\z/;
      unless ($days) {
        warn "skipping event with wonky duration\n";
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

    %$cache = (cached_at => time, leave_days => \%leave_days);
    return \%leave_days;
  }

  sub user_is_available_on ($self, $username, $dt) {
    my $ymd = $dt->ymd;

    my $leave = $self->_leave_days;
    return 1 if $leave->{$username}{$dt->ymd};

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
