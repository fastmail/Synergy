use v5.32.0;
use warnings;
package Synergy::Reactor::TimeClock;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences',
     ;

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Synergy::Logger '$Logger';
use Synergy::Util qw(bool_from_text describe_business_hours);

use DBI;
use Future::AsyncAwait;
use IO::Async::Timer::Periodic;
use List::Util qw(max);

use utf8;

sub listener_specs {
  return (
    {
      name      => 'now_working',
      method    => 'handle_now_working',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /\Anow\s+working\s*\z/i; },
      help_entries => [
        {
          title => 'now working',
          text  => "*now working*: list everyone who's currently on the clock",
        },
      ],
    },
    {
      name      => 'hours_for',
      method    => 'handle_hours_for',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /\Ahours(\s+for)?\s+/i; },
      help_entries => [
        {
          title => 'hours',
          text  => "*hours PERSON* (or *hours for PERSON*): find out when PERSON is likely to be working",
        },
      ],
    },
    {
      name      => 'clock_out',
      method    => 'handle_clock_out',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /\Aclock\s*(?:out|off):/; },
      help_entries => [
        {
          title => 'clock out',
          text  => "*clock out: `[REPORT]`*: declare you're done for the day and file a brief report about it",
        },
        {
          title => 'clock off',
          text  => 'see *clock out*',
          unlisted => 1,
        },
      ],
    },
    {
      name      => 'recent_clockouts',
      method    => 'handle_recent_clockouts',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { lc $e->text eq 'recent clockouts'; },
      help_entries => [
        {
          title => 'clockouts',
          text  => '*recent clockouts*: give a summary of clockouts for the past 48h',
        },
      ],
    },
  );
}

has primary_channel_name => (
  is  => 'ro',
  isa => 'Str',
  required => 1, # TODO: die during registration if ∄ channel
);

has clock_out_address => (
  is  => 'ro',
  isa => 'Str',
);

has clock_out_channel => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) { $self->hub->channel_named($self->primary_channel_name) }
);

sub state ($self) {
  return {
    last_report_time => $self->last_report_time,
    user_last_report_times => $self->user_last_report_times,
  };
}

async sub start ($self) {
  my $timer = IO::Async::Timer::Periodic->new(
    notifier_name => 'timeclock-shift-change',
    interval => 15 * 60,
    on_tick  => sub { $self->check_for_shift_changes; },
  );

  $self->hub->loop->add($timer);

  $timer->start;

  $self->check_for_shift_changes;

  return;
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $epoch = $state->{last_report_time}) {
      $self->last_report_time($epoch);
    }

    if (my $times = $state->{user_last_report_times}) {
      $self->_set_user_last_report_times($times);
    }
  }
};

has timeclock_dbfile => (
  is => 'ro',
  isa => 'Str',
  default => "timeclock.sqlite",
);

has _timeclock_dbh => (
  is  => 'ro',
  lazy     => 1,
  init_arg => undef,
  default  => sub ($self, @) {
    my $dbf = $self->timeclock_dbfile;

    my $dbh = DBI->connect(
      "dbi:SQLite:dbname=$dbf",
      undef,
      undef,
      { RaiseError => 1 },
    );
    die $DBI::errstr unless $dbh;

    $dbh->do(q{
      CREATE TABLE IF NOT EXISTS reports (
        id INTEGER PRIMARY KEY,
        from_user TEXT NOT NULL,
        reported_at INTEGER NOT NULL,
        report TEXT NOT NULL
      );
    });

    return $dbh;
  },
);

sub handle_now_working ($self, $event) {
  $event->mark_handled;

  my $moment = DateTime->now;
  my $roto   = $self->hub->reactor_named('rototron');

  my @at_home;
  my @in_office;

  for my $user (sort { $a->username cmp $b->username } $self->hub->user_directory->users) {
    next if $user->is_virtual;
    next unless $user->is_working_now;

    my $when  = DateTime->from_epoch(
      time_zone => $user->time_zone,
      epoch     => $moment->epoch,
    );

    # We can use this, later, to get "until X" but we want to make it friendly
    # time for the asking user. -- rjbs, 2022-06-23
    next unless my $hours = $user->hours_for_dow($when->day_of_week);

    next if $roto && ! $roto->rototron->user_is_available_on($user->username, $when);

    my $dow = [ qw(sun mon tue wed thu fri sat) ]->[ $when->day_of_week % 7 ];
    my $wfh = $user->is_wfh_on($dow);

    if ($wfh) {
      push @at_home, $user->username;
    } else {
      push @in_office, $user->username;
    }
  }

  unless (@at_home || @in_office) {
    return $event->reply("How about that!  Nobody's working right now.");
  }

  if ($event->is_public) {
    $event->reply("I don't want to ping everybody who's working, so I've replied in private.");
  }

  my $text = q{};

  if (@in_office) {
    $text .= "\N{OFFICE BUILDING} " . (join q{, }, @in_office) . "\n";
  }

  if (@at_home) {
    $text .= "\N{HOUSE WITH GARDEN} " . (join q{, }, @at_home) . "\n";
  }

  $event->private_reply("Currently on the clock:\n$text");
}

sub handle_hours_for ($self, $event) {
  $event->mark_handled;

  my ($who) = $event->text =~ /\Ahours(?:\s+for)?\s+(\S+)\s*\z/i;

  my $target = $self->resolve_name($who, $event->from_user);

  unless ($target) {
    return $event->reply_error("Sorry, I don't know who that is.");
  }

  my $tz = $target->time_zone;
  my $tz_nick = $self->hub->env->time_zone_names->{ $tz } // $tz;


  return $event->reply(
    sprintf "%s's usual hours (%s): %s",
      $target->username,
      $tz_nick,
      describe_business_hours($target->business_hours, $target),
  );
}

sub handle_clock_out ($self, $event) {
  $event->mark_handled;

  my ($w2, $comment) = $event->text =~ /^clock\s*(out|off):\s*(\S.+)\z/is;

  unless ($comment) {
    return $event->error_reply("To clock \L$w2\E, it's: *clock \L$w2\E: `SUMMARY`*.");
  }

  unless ($event->from_user) {
    return $event->error_reply("I don't know who you are, so you can't clock \L$w2\E.");
  }

  $self->_timeclock_dbh->do(
    "INSERT INTO reports (from_user, reported_at, report) VALUES (?, ?, ?)",
    undef,
    $event->from_user->username,
    $event->time,
    $comment,
  );

  if ( $self->clock_out_channel
    && $self->clock_out_address
    && $event->conversation_address ne $self->clock_out_address
  ) {
    my $username = $event->from_user->username;
    $self->clock_out_channel->send_message(
      $self->clock_out_address,
      "$username just clocked out: $comment"
    );
  }

  if ($event->is_public) {
    return $event->reply("See you later!");
  }

  return $event->reply("See you later! Next time, consider clocking \L$w2\E in public!");
}

sub handle_recent_clockouts ($self, $event) {
  $event->mark_handled;

  my $reports = $self->_timeclock_dbh->selectall_arrayref(
    "SELECT from_user, reported_at, report FROM reports WHERE reported_at >= ?",
    { Slice => {} },
    time  -  86_400 * 2,
  );

  my $hub = $self->hub;
  my $dir = $hub->user_directory;

  my $text = q{};
  for my $report (sort {; $a->{reported_at} <=> $b->{reported_at} } @$reports) {
    my $user = $dir->user_named($report->{from_user});
    my $when = $user
      ? $user->format_timestamp($report->{reported_at})
      : $hub->format_friendly_date( DateTime->from_epoch(epoch => $report->{reported_at}) );

    $text .= sprintf "*%s, %s*: %s\n",
      $report->{from_user},
      $when,
      Encode::decode('UTF-8', $report->{report});
  }

  chomp $text;

  $event->reply(
    $text
      ? "*Recent Clockings Out*\n$text"
      : "There have been no recent clockings out!"
  );
}

sub has_clocked_out_report ($self, $who, $arg = {}) {
  my $recent = $self->_timeclock_dbh->selectall_arrayref(
    "SELECT reported_at, report FROM reports
    WHERE reported_at >= ? AND from_user = ?
    ORDER BY reported_at DESC",
    { Slice => {} },
    time  -  3600 * 12,
    $who->username,
  );

  unless (@$recent) {
    return Future->done([
      "🕔❓ You haven't clocked out yet today.",
      { slack => "🕔❓ You haven't clocked out yet today." },
    ]);
  }

  my $time = $who->format_timestamp($recent->[0]{reported_at});
  return Future->done([
    "🕔✅ You already clocked out at $time!",
    { slack => "🕔✅ You already clocked out at $time!" },
  ]);
}

has last_report_time => (
  is   => 'rw',
  isa  => 'Int',
  lazy => 1,
  default => $^T - 900
);

# username => time
has user_last_report_times => (
  is => 'ro',
  lazy => 1,
  default => sub { {} },
  traits => [ 'Hash' ],
  writer => '_set_user_last_report_times',
  handles => {
    last_report_time_for => 'get',
    set_last_report_time_for  => 'set',
  }
);

after set_last_report_time_for => sub ($self, @) {
  $self->save_state;
};

sub check_for_shift_changes ($self) {
  my $report_reactor = $self->hub->reactor_named('report');
  return unless $report_reactor; # TODO: fatalize during startup..?

  my $channel = $self->hub->channel_named($self->primary_channel_name);

  # Okay, here's the deal.  We want to remind people of their civic duty, which
  # means telling them:
  #
  # * shortly after shift starts, what work is on their plate for the day
  # * shortly before shift ends,  whether they have missed key work
  #
  # We want to find people who have come on duty in the last 15m, unless we've
  # already sent a report in the last 15m.  Also, anyone who will end their
  # shift in the next 15m, unless we already covered that time.
  #
  # If we've been offline for a good long time (oh no!) let's not give people
  # reports that are more than two hours overdue.  First off, it's just polite.
  # Secondly, it will prevent us from doing weird things like sending both
  # morning and evening reports. -- rjbs, 2019-11-08
  my $now  = time;
  my $global_last = max($self->last_report_time, $now - 7200);

  my %if = (
    morning => sub ($s, $e) { $s > $global_last       && $s <= $now },
    evening => sub ($s, $e) { $e > $global_last + 900 && $e <= $now + 900 },
  );

  my %report = map {; $_ => $report_reactor->report_named($_) } keys %if;

  return unless grep {; defined } values %report;

  $Logger->log("TimeClock: checking for shift changes");

  my $now_dt = DateTime->from_epoch(epoch => $now);

  USER: for my $user ($self->hub->user_directory->users) {
    next unless $user->has_identity_for($channel->name);

    next unless my $shift = $user->shift_for_day($self->hub, $now_dt);

    next if $self->get_user_preference($user, 'suppress-reports');

    my $user_last = $self->last_report_time_for($user->username) // 0;

    next if $now - $user_last < 300;  # not more than one every 5m

    for my $which (sort keys %if) {
      my $will_send = $if{$which}->($shift->@{ qw(start end) });

      $Logger->log_debug([
        "TimeClock: DEBUG: %s",
        {
          global_last => $global_last,
          user_last   => $user_last,
          now       => $now,
          which     => $which,
          who       => $user->username,
          will_send => $will_send,
          $shift->%{ qw(start end) },
        },
      ]);

      next unless $will_send;

      $Logger->log([ "kicking off %s report for %s", $which, $user->username ]);
      my $report = $report_reactor->begin_report($report{$which}, $user);

      $report
        ->else(sub (@error) {
          $Logger->log([
            "ERROR sending %s report to %s: %s",
            $which,
            $user->username,
            "@error",
          ]);
          Future->done;
        })
        ->then(sub ($text, $alts) {
          unless (defined $text) {
            # I don't know anymore whether this is odd.  Rather than audit, I'm
            # going to add this log line and then either drop it when I realize
            # it happens all the time on purpose *or* fix things where it shows
            # up. -- rjbs, 2024-04-19
            $Logger->log([
              "no text returned by %s report for %s",
              $which,
              $user->username,
            ]);
            return Future->done;
          }

          $Logger->log([ "sending %s report for %s", $which, $user->username ]);
          $channel->send_message_to_user($user, $text, $alts);

          $self->set_last_report_time_for($user->username, $now);
          return Future->done;
        })
        ->retain;

      next USER;
    }
  }

  $self->last_report_time($now);
  $self->save_state;
}

__PACKAGE__->add_preference(
  name      => 'suppress-reports',
  validator => async sub ($self, $value, @) { return bool_from_text($value) },
  default   => 0,
);

1;
