use v5.36.0;
use utf8;
package Synergy::Reactor::PagerDuty;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use namespace::clean;

use Carp ();
use Data::Dumper::Concise;
use DateTime;
use DateTime::Format::ISO8601;
use Future;
use Future::AsyncAwait;
use IO::Async::Timer::Periodic;
use JSON::MaybeXS qw(decode_json encode_json);
use Lingua::EN::Inflect qw(PL_N PL_V);
use List::Util qw(first uniq);
use Slack::BlockKit::Sugar -all => { -prefix => 'bk_' };
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(reformat_help);
use Time::Duration qw(ago duration);
use Time::Duration::Parse qw(parse_duration);

my $ISO8601 = DateTime::Format::ISO8601->new;

has api_endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  default => 'https://api.pagerduty.com',
);

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# the id for "Platform" or whatever. If we wind up having more than one
# "service", we'll need to tweak this
has service_ids => (
  is => 'ro',
  isa => 'ArrayRef',
  required => 1,
);

# used for getting oncall names
has escalation_policy_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has _suppressed_user_ids => (
  is  => 'ro',
  isa => 'ArrayRef',
  traits   => ['Array'],
  default  => sub {  []  },
  handles  => { suppressed_user_ids => 'elements' },
  init_arg => 'suppressed_user_ids',
);

has _pd_to_slack_map => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  clearer => '_clear_pd_to_slack_map',
  handles => {
    username_from_pd => 'get',
  },
  default => sub ($self) {
    my %map;

    for my $sy_username (keys $self->user_preferences->%*) {
      my $pd_id = $self->get_user_preference($sy_username, 'user-id');
      $map{$pd_id} = $sy_username;
    }

    return \%map;
  },
);

has _slack_to_pd_map => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  clearer => '_clear_slack_to_pd_map',
  handles => {
    pd_id_from_username => 'get',
  },
  default => sub ($self) {
    my %map = reverse $self->_pd_to_slack_map->%*;
    return \%map;
  },
);

has oncall_channel_name => (
  is => 'ro',
  isa => 'Str',
);

has oncall_channel => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return unless my $channel_name = $self->oncall_channel_name;
    return $self->hub->channel_named($channel_name);
  }
);

has oncall_group_address => (
  is => 'ro',
  isa => 'Str',
);

has maint_warning_address => (
  is  => 'ro',
  isa => 'Str',
);

has oncall_change_announce_address => (
  is  => 'ro',
  isa => 'Str',
);

has maint_timer_interval => (
  is => 'ro',
  isa => 'Int',
  default => 600,
);

has last_maint_warning_time => (
  is => 'rw',
  isa => 'Int',
  default => 0,
);

has oncall_list => (
  isa => 'ArrayRef',
  traits => [ 'Array' ],
  writer => '_set_oncall_list',
  lazy => 1,
  default => sub { [] },
  handles => { oncall_list => 'elements' },
);

around '_set_oncall_list' => sub ($orig, $self, @rest) {
  $self->$orig(@rest);
  $self->save_state;
};

async sub start ($self) {
  if ($self->oncall_channel && $self->oncall_group_address) {
    my $check_oncall_timer = IO::Async::Timer::Periodic->new(
      notifier_name  => 'pagerduty-oncall',
      first_interval => 30,   # don't start immediately
      interval       => 150,
      on_tick        => sub { $self->_check_at_oncall },
    );

    $check_oncall_timer->start;
    $self->hub->loop->add($check_oncall_timer);

    # No maint warning timer unless we can warn oncall
    if ($self->oncall_group_address && $self->maint_warning_address) {
      my $maint_warning_timer = IO::Async::Timer::Periodic->new(
        notifier_name  => 'pagerduty-maint',
        first_interval => 45,
        interval => $self->maint_timer_interval,
        on_tick  => sub {  $self->_check_long_maint },
      );
      $maint_warning_timer->start;
      $self->hub->loop->add($maint_warning_timer);
    }
  }

  return;
}

# "start /force" is not documented here because it will mention itself to the
# user when needed -- rjbs, 2020-06-15
help maint => reformat_help(<<~"EOH");
  Conveniences for managing PagerDuty's "maintenance mode", aka "silence all
  the alerts because everything is on fire."

  • *maint status*: show current maintenance state
  • *maint start*: enter maintenance mode. All alerts are now silenced! Also
  acks
  • *maint end*, *demaint*, *unmaint*, *stop*: leave maintenance mode. Alerts
  are noisy again!

  When you leave maintenance mode, any alerts that happened during it, or even
  shortly before it, will be marked resolved.  If you don't want that, say
  *maint end /noresolve*
  EOH

responder 'maint-status' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1, # provided by "help maint"
  matcher => sub ($self, $text, $event) {
    return [] if $text =~ /\Amaint(\s+status)?\s*\z/ni;
    return;
  }
} => async sub ($self, $event) {
  $event->mark_handled;

  my @maints = await $self->_relevant_maint_windows;

  unless (@maints) {
    return await $event->reply("PagerDuty not in maint right now. Everything is fine maybe!");
  }

  my $maint_text = $self->_format_maints(@maints);
  return await $event->reply("🚨 PagerDuty in maint: $maint_text");
};

responder 'maint-start' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1, # provided by "help maint"
  matcher => sub ($self, $text, $event) {
    return [ $1 ? 1 : 0 ] if $text =~ m{\Amaint\s+start(\s+/force)?\s*\z}i;
    return;
  },
} => async sub ($self, $event, $force) {
  $event->mark_handled;

  unless ($self->is_known_user($event)) {
    return await $event->error_reply("I don't know you, so I'm ignoring that.");
  }

  unless ($force) {
    my $is_oncall = await $self->_user_is_oncall($event->from_user);

    unless ($is_oncall) {
      return await $event->error_reply(join(q{ },
        "You don't seem to be on call right now.",
        "Usually, the person oncall is getting the alerts, so they should be",
        "the one to decide whether or not to shut them up.",
        "If you really want to do this, try again with /force."
      ));
    }
  }

  my @maints = await $self->_relevant_maint_windows;

  if (@maints) {
    my $desc = $self->_format_maints(@maints);
    return await $event->reply("PagerDuty already in maint: $desc");
  }

  my @services = map {; { type => 'service_reference', id => $_} } $self->service_ids->@*;

  # XXX add reason here?
  my $data = await $self->_pd_request_for_user(
    $event->from_user,
    POST => '/maintenance_windows',
    {
      maintenance_window => {
        type => 'maintenance_window',
        start_time => $ISO8601->format_datetime(DateTime->now),
        end_time   =>  $ISO8601->format_datetime(DateTime->now->add(hours => 1)),
        services => \@services
      },
    }
  );

  my $n_acked = await $self->_ack_all($event);
  my $ack_text = ' ';
  $ack_text = " 🚑 $n_acked alert".($n_acked > 1 ? 's' : '')." acked!"
    if $n_acked;

  return await $event->reply("🚨 PagerDuty now in maint for an hour!$ack_text Good luck!");
};

responder 'maint-end' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1, # provided by "help maint"
  matcher => sub ($self, $text, $event) {
    return [ ] if $text =~ m{\Amaint\s+(end|stop)\s*\z}ni;
    return [ ] if $text =~ m{\Aunmaint\s*\z}ni;
    return [ ] if $text =~ m{\Ademaint\s*\z}ni;
    return;
  },
} => async sub ($self, $event) {
  $event->mark_handled;

  unless ($self->is_known_user($event)) {
    return await $event->error_reply("I don't know you, so I'm ignoring that.");
  }

  my @maints = await $self->_relevant_maint_windows;

  unless (@maints) {
    return await $event->reply("PagerDuty not in maint right now. Everything is fine maybe!");
  }

  # add 5s to allow for clock skew, otherwise PagerDuty gives you "end cannot
  # be before now"
  my $now = $ISO8601->format_datetime(DateTime->now->add(seconds => 5));

  my @futures;
  for my $window (@maints) {
    my $id = $window->{id};
    push @futures, $self->_pd_request_for_user(
      $event->from_user,
      PUT => "/maintenance_windows/$id",
      {
        maintenance_window => {
          type       => $window->{type},
          end_time   => $now,
        },
      }
    );
  }

  await Future->wait_all(@futures);

  my @failed = grep {; $_->is_failed } @futures;

  unless (@failed) {
    return await $event->reply("🚨 PagerDuty maint cleared. Good job everyone!");
  }

  $Logger->log([ "PagerDuty demaint failed: %s", [ map {; $_->failure } @failed ] ]);
  return await $event->reply(
    "Something went wrong fiddling PagerDuty maint state; you'll probably want to sort it out on the web. Sorry about that!"
  );
};

command oncall => {
  help => '*oncall*: show a list of who is on call in PagerDuty right now',
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->reply_error(q{It's just "oncall".  Did you want "give oncall"?});
  }

  my $reply = "";
  my $oncall_tree = await $self->_oncall_tree;

  my @levels = sort { $a <=> $b } keys %$oncall_tree;
  my $max_level = $levels[-1];

  for my $level (@levels) {
    my @users = uniq map {; $self->username_from_pd($_->{user}{id}) // $_->{user}{id} } $oncall_tree->{$level}->@*;

    my $extra = $level == 1          ? " (primary oncall)"
              : $level == 2          ? " (primary escalation)"
              : $level == $max_level ? " (final escalation)"
              :                        "";

    $reply .= "Level $level$extra: " . join(', ', sort @users);

    $reply .= "\n" if ($level != $max_level);
  }

  return await $event->reply($reply);
};

help "give oncall" => reformat_help(<<~'EOH'),
  Give the oncall conch to someone for a while.

  • `give oncall to WHO [for DURATION]`

  `WHO` is the person you want to take the conch, and `DURATION` is how long
  they should keep it. The duration is parsed, so you can say something like
  "30m" or "2h".

  Instead of a username, `WHO` may be the special word "escalation", which will
  figure out who is currently the fallback oncall and give oncall to them.
  In this case, it will also close (resolve) any unsnoozed alerts you had
  acknowledge, so that they can retrigger for them.

  The `DURATION` is optional if you are giving oncall to escalation, and will
  then just override for the entire rest of your shift. Otherwise, the maximum
  duration is 8 hours.

  This command is intended for the case where you're oncall and need to step
  away for a while due to personal matters or travel.
  You cannot give oncall to someone for more than 8 hours with the `DURATION`
  argument, and if there is more than one person oncall, it cannot determine
  whose oncall to override, unless the oncall person is you.
  To set up extended overrides, you should use the PagerDuty website.
  EOH

responder 'give-oncall' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1, # provided by "help give oncall"
  matcher => sub ($self, $text, $event) {
    my ($who, $for, $dur) = $text =~ /\Agive\s+oncall\s+to\s+(\S+)(\s+for\s+(.*))?\s*$/i;
    return [ $who, $dur ] if $who && $for;
    return [ $who, undef ] if $who;
    return;
  },
} => async sub ($self, $event, $who, $dur) {
  # For now, this will work in *extremely* limited situations, so we do a bunch
  # of error checking up front here.
  $event->mark_handled;

  my $target_id;
  my $target;

  my $is_escalation = $who eq 'escalation';

  if ($is_escalation) {
    my $escalations = await $self->_relevant_oncalls(2);

    $who = $self->username_from_pd($escalations->[0]{user}{id});
    $who ||= $escalations->[0]{user}{id}; # fallback mainly for debugging if we don't have a full user directory

    $target_id = $escalations->[0]{user}{id};
  }

  unless ($target_id) {
    $target = $self->resolve_name($who, $event->from_user);
    unless ($target) {
      return await $event->error_reply("Sorry, I can't figure out who '$who' is.");
    }

    $target_id = $self->get_user_preference($target, 'user-id');
  }

  unless ($target_id) {
    my $they = $target->username;
    return await $event->error_reply("Hmm, $they doesn't seem to be a PagerDuty user.");
  }

  my $oncalls = await $self->_relevant_oncalls;
  my $from_oncall;

  if (@$oncalls == 1) {
    $from_oncall = $oncalls->[0];
  } else {
    for my $oncall (@$oncalls) {
      if ($self->username_from_pd($oncall->{user}{id}) eq $event->from_user->{username}) {
        $from_oncall = $oncall;
        last;
      }
    }
  }

  if (!$from_oncall) {
    return await $event->error_reply(
      "Sorry; there's more than one person oncall right now and you're not one of them, so I can't help you!"
    );
  }


  my $start    = DateTime->now->add(seconds => 15);
  my $seconds;

  if ($dur) {
    $seconds = eval { parse_duration($dur) };
    unless ($seconds) {
      return await $event->error_reply("Hmm, I can't figure out how long you mean by '$dur'.");
    }

    if ($seconds > 60 * 60 * 8) {
      return await $event->error_reply("Sorry, I can only give oncall for 8 hours max.");
    }

    if ($seconds < 60 ) {
      return await $event->error_reply("That's less than a minute; did you forget a unit?");
    }
  } else {
    if ($from_oncall->{end}) {
      # FIXME: This is a weird epicycle, because we need to convert the seconds
      # into the end time against when we submit it to the API.
      # We only really need the seconds for the reply at the end, so this should
      # be rejiggered
      my $end = $ISO8601->parse_datetime($from_oncall->{end});
      $seconds = $end->clone->subtract_datetime_absolute($start)->seconds;
    } else {
      return await $event->error_reply(
        "There's no shift end for the shift you're trying to override so I cannot " .
        "figure out from context how long to override for. Please specify duration."
      );
    }
  }


  my $schedule = $oncalls->[0]{schedule};
  unless ($schedule) {
    return await $event->error_reply("Sorry; I couldn't figure out the oncall schedule from PagerDuty.");
  }

  my $sched_id = $schedule->{id};
  my $end      = $start->clone->add(seconds => $seconds);

  my $overrides = await  $self->_pd_request_for_user(
    $event->from_user,
    POST => "/schedules/$sched_id/overrides",
    {
      overrides => [{
        start => $ISO8601->format_datetime($start),
        end   => $ISO8601->format_datetime($end),
        user  => {
          type => 'user_reference',
          id   => $target_id,
        },
      }],
    }
  );

  unless (@$overrides == 1 && $overrides->[0]{status} == 201) {
    $Logger->log([ "got weird data back from override call: %s", $overrides ]);
    return await $event->reply(
      "Sorry, something went wrong talking to PagerDuty. \N{DISAPPOINTED FACE}"
    );
  }

  if ($is_escalation) {
    await $self->_resolve_incidents($event, {
      whose => 'own',
      only_pending => 1,
    });
  }

  my $target_str = $target ? $target->username : $target_id;

  return await $event->reply(
    sprintf("Okay! %s is now oncall for %s.",
      $target_str,
      duration($seconds),
    )
  );
};

command ack => {
  help => '*ack all*: acknowledge all triggered alerts in PagerDuty',
} => async sub ($self, $event, $rest) {
  unless ($rest && $rest eq 'all') {
    return await $event->error_reply(q{The only thing you can "ack" is "all".});
  }

  unless ($self->is_known_user($event)) {
    return await $event->error_reply("I don't know you, so I'm ignoring that.");
  }

  my $n_acked = await $self->_ack_all($event);

  my $noun = $n_acked == 1 ? 'incident' : 'incidents';
  $event->reply("Successfully acked $n_acked $noun. Good luck!");
};

command incidents => {
  help => '*incidents*: list current active incidents',
  aliases => [ 'alerts' ],
} => async sub ($self, $event, $rest) {
  my $summary = await $self->_active_incidents_summary;
  my $text    = delete $summary->{text} // "The board is clear!";

  return await $event->reply($text, $summary);
};

command resolve => {
  help => reformat_help(<<~'EOH'),
    *resolve*: manage resolving alerts in PagerDuty

    You can run this in one of several ways:

    • *resolve all*: resolve all triggered and acknowledged alerts in PagerDuty
    • *resolve acked*: resolve the acknowledged alerts in PagerDuty
    • *resolve mine*: resolve the acknowledged alerts assigned to you in PagerDuty
    EOH
} => async sub ($self, $event, $rest) {
  unless ($self->is_known_user($event)) {
    return await $event->error_reply("I don't know you, so I'm ignoring that.");
  }

  if ($rest eq 'all')   {
    return await $self->_resolve_incidents($event, { whose => 'all' });
  }

  if ($rest eq 'acked') {
    return await $self->_resolve_incidents($event, {
      whose => 'all',
      only_acked => 1,
    });
  }

  if ($rest eq 'mine') {
    return await $self->_resolve_incidents($event, {
      whose => 'own',
    });
  }

  return await $event->error_reply("I don't know what you want to ack.  Check the help!");
};

command snooze => {
  help => 'Snooze a single PagerDuty incident. Usage: snooze ALERT-NUMBER for DURATION',
} => async sub ($self, $event, $rest) {
  my ($num, $dur) = $rest =~ /^#?(\d+)\s+for\s+(.*)/i;

  unless ($num && $dur) {
    return await $event->error_reply(
      "Sorry, I don't understand. Say 'snooze INCIDENT-NUM for DURATION'."
    );
  }

  my $seconds = eval { parse_duration($dur) };

  unless ($seconds) {
    return await $event->error_reply("Sorry, I couldn't parse '$dur' into a duration!");
  }

  my @incidents = await $self->_get_incidents(qw(triggered acknowledged));

  my ($relevant) = grep {; $_->{incident_number} == $num } @incidents;
  unless ($relevant) {
    return await $event->error_reply("I couldn't find an active incident for #$num");
  }

  my $id = $relevant->{id};

  my $res = await $self->_pd_request_for_user(
    $event->from_user,
    POST => "/incidents/$id/snooze",
    { duration => $seconds }
  );

  if (my $incident = $res->{incident}) {
    my $title = $incident->{title};
    my $duration = duration($seconds);
    return await $event->reply(
      "#$num ($title) snoozed for $duration; enjoy the peace and quiet!"
    );
  }

  my $msg = $res->{message} // 'nothing useful';

  return await $event->reply(
    "Something went wrong talking to PagerDuty; they said: $msg"
  );
};

sub state ($self) {
  return {
    oncall_list => [ $self->oncall_list ],
    last_maint_warning_time => $self->last_maint_warning_time,
  };
}

sub _url_for ($self, $endpoint) {
  return $self->api_endpoint_uri . $endpoint;
}

sub is_known_user ($self, $event) {
  my $user = $event->from_user;

  return 1 if $user && $self->get_user_preference($user, 'api-token');

  if (! $user) {
    $event->reply("Sorry, I don't even know who you are!");
    return 0;
  }

  my $name = $user->username;
  my $ns = $self->preference_namespace;
  $event->reply(
    "You look like my old friend $name, but you haven't set your "
    . "$ns.api-token yet, so I can't help you here, sorry."
  );

  return 0;
}

# this is way too many positional args, but...meh.
sub _pd_request_for_user ($self, $user, $method, $endpoint, $data = undef) {
  my $token = $self->get_user_preference($user, 'api-token');
  return $self->_pd_request($method => $endpoint, $data, $token);
}

sub _pd_request ($self, $method, $endpoint, $data = undef, $token = undef) {
  my %content;

  if ($data) {
    %content = (
      Content_Type => 'application/json',
      Content      => encode_json($data),
    );
  }

  return $self->hub->http_request(
    $method,
    $self->_url_for($endpoint),
    Authorization => 'Token token=' . ($token // $self->api_key),
    Accept        => 'application/vnd.pagerduty+json;version=2',
    %content,
  )->then(sub ($res) {
    unless ($res->is_success) {
      my $code = $res->code;
      $Logger->log([ "error talking to PagerDuty: %s", $res->as_string ]);
      return Future->fail('http', { http_res => $res });
    }

    my $data = decode_json($res->content);
    return Future->done($data);
  });
}

after register_with_hub => sub ($self, @) {
  my $state = $self->fetch_state // {};   # load prefs
  if (my $list = $state->{oncall_list}) {
    $self->_set_oncall_list($list);
  }

  if (my $when = $state->{last_maint_warning_time}) {
    $self->last_maint_warning_time($when);
  }
};

sub _relevant_maint_windows ($self) {
  return $self->_pd_request('GET' => '/maintenance_windows?filter=ongoing')
    ->then(sub ($data) {
      my $maint = $data->{maintenance_windows} // [];

      # create a search/lookup hash
      my %services = map {; $_ => 1} $self->service_ids->@*;

      # We only care if maint window covers a service we care about.
      my @relevant;
      for my $window (@$maint) {
        next unless grep {; $services{$_->{id}} } $window->{services}->@*;
        push @relevant, $window;
      }

      return Future->done(@relevant);
    });
}

sub _format_maints ($self, @maints) {
  return join q{; }, map {; $self->_format_maint_window($_) } @maints;
}

sub _format_maint_window ($self, $window) {
  my $services = join q{, }, map {; $_->{summary} } $window->{services}->@*;
  my $start = $ISO8601->parse_datetime($window->{start_time});
  my $ago = ago(time - $start->epoch);
  my $who = $window->{created_by}->{summary};   # XXX map to our usernames

  return "$services ($ago, started by $who)";
}

sub _check_long_maint ($self) {
  my $current_time = time();

  # No warning if we've warned in last 25 minutes
  return unless ($current_time - $self->last_maint_warning_time) > (60 * 25);

  $self->_relevant_maint_windows
    ->then(sub (@maint) {
      unless (@maint) {
        return Future->fail('not in maint');
      }

      $self->last_maint_warning_time($current_time);
      $self->save_state;

      my $oldest;
      for my $window (@maint) {
        my $start = $ISO8601->parse_datetime($window->{start_time});
        my $epoch = $start->epoch;
        $oldest = $epoch if ! $oldest || $epoch < $oldest;
      }

      my $maint_duration_s = $current_time - $oldest;
      return Future->fail('maint duration less than 30m')
        unless $maint_duration_s > (60 * 30);

      my $group_address = $self->oncall_group_address;
      my $maint_duration_m = int($maint_duration_s / 60);

      my $maint_text = $self->_format_maints(@maint);
      my $text =  "Hey, by the way, PagerDuty is in maintenance mode: $maint_text";

      $self->oncall_channel->send_message(
        $self->maint_warning_address,
        "\@oncall $text",
        { slack => "<!subteam^$group_address> $text" }
      );
    })
    ->else(sub {
      my ($message, $extra) = @_;
      return if $message eq 'not in maint';
      return if $message eq 'maint duration less than 30m';
      $Logger->log([ "PagerDuty error _check_long_maint(): %s", [@_] ]);
    })->retain;
}

sub _oncall_tree($self) {

  my %should_ignore = map {; $_ => 1 } $self->suppressed_user_ids;

  return $self->_pd_request(GET => '/oncalls?escalation_policy_ids[]=' . $self->escalation_policy_id)
    ->then(sub ($data) {

      my %oncall_tree;

      my @oncalls = grep {; !$should_ignore{$_->{user}{id}} } $data->{oncalls}->@*;

      for my $oncall (@oncalls) {
        my $level = $oncall->{escalation_level};

        if (!$oncall_tree{$level}) {
          $oncall_tree{$level} = [];
        }

        push $oncall_tree{$level}->@*, $oncall;
      }

      return Future->done(\%oncall_tree);
    });

}

# gets all currently on call users and filters for the appropriate escalation level.
# level 1 == primary oncall
# level 2 == primary escalation
# final level == all hands on deck
async sub _relevant_oncalls ($self, $level = 1) {
  my $oncall_tree = await $self->_oncall_tree;
  return $oncall_tree->{$level};
}

async sub _current_oncall_ids ($self) {
  my $oncalls = await $self->_relevant_oncalls;
  my @ids = map {; $_->{user}{id} } @$oncalls;
  return @ids;
}

# returns all the oncall users on the final escalation rule
# used for "page all oncall engineers"
async sub _escalation_oncall_ids ($self) {

  my $oncall_tree = await $self->_oncall_tree;

  my @levels = sort { $a <=> $b } keys %$oncall_tree;
  my $max_level = $levels[-1];

  my @ids = map {; $_->{user}{id} } $oncall_tree->{$max_level}->@*;

  return @ids;
}

# This returns a Future that, when done, gives a boolean as to whether or not
# $who is oncall right now.
sub _user_is_oncall ($self, $who) {
  return $self->_current_oncall_ids
    ->then(sub (@ids) {
      my $want_id = $self->get_user_preference($who->username, 'user-id');
      return Future->done(!! first { $_ eq $want_id } @ids)
    });
}

# returns a future that yields a list of incidents
sub _get_incidents ($self, @statuses) {
  Carp::confess("no statuses found to get!") unless @statuses;

  # url params
  my $offset   = 0;
  my $limit    = 100;
  my $services = join q{&}, map {; "service_ids[]=$_" } $self->service_ids->@*;
  my $statuses = join q{&}, map {; "statuses[]=$_" } @statuses;

  # iteration variables
  my $is_done = 0;
  my $i = 0;
  my @results;

  while (! $is_done) {
    my $url = "/incidents?$services&$statuses&limit=$limit&offset=$offset";

    $self->_pd_request(GET => $url)
      ->then(sub ($data) {
        push @results, $data->{incidents}->@*;

        $is_done = ! $data->{more};
        $offset += $limit;

        if (++$i > 20) {
          $Logger->log("did more than 20 requests getting incidents from PagerDuty; aborting to avoid infinite loop!");
          $is_done = 1;
        }
      })
      ->await;
  }

  return Future->done(@results);
}

async sub _get_incident_notes ($self, $incident_id) {
  my $url = "/incidents/$incident_id/notes";
  my $notes_data = await $self->_pd_request(GET => $url);

  return $notes_data->{notes};
}

sub _update_status_for_incidents ($self, $who, $status, $incident_ids) {
  # This just prevents some special-casing elsewhere
  return Future->done unless @$incident_ids;

  my @todo = @$incident_ids;
  my @incidents;

  # *Surely* we won't have more than 500 at a time, right? Right?! Anyway,
  # 500 is the PagerDuty max for this endpoint.
  while (my @ids = splice @todo, 0, 500) {
    my @put = map {;
      +{
        id => $_,
        type => 'incident_reference',
        status => $status,
      },
    } @ids;

    $self->_pd_request_for_user(
      $who,
      PUT => '/incidents',
      { incidents => \@put }
    )->then(sub ($data) {
      push @incidents, $data->{incidents}->@*;
    })
    ->await;
  }

  return Future->done(@incidents);
}

sub _ack_all ($self, $event) {
  return $self->_get_incidents(qw(triggered))
    ->then(sub (@incidents) {
      my @unacked = map  {; $_->{id} } @incidents;
      $Logger->log([ "PagerDuty: acking incidents: %s", \@unacked ]);

      return $self->_update_status_for_incidents(
        $event->from_user,
        'acknowledged',
        \@unacked,
      );
    })->then(sub (@incidents) {
      return Future->done(scalar @incidents);
    });
}

sub _resolve_incidents($self, $event, $arg) {
  my $whose = $arg->{whose};
  my $only_pending = $arg->{only_pending};
  Carp::confess("_resolve_incidents called with bogus args")
    unless $whose && ($whose eq 'all' || $whose eq 'own');

  my $only_acked = $arg->{only_acked} // ($whose eq 'own' ? 1 : 0);

  my $pending_cutoff = DateTime->now->add(minutes => 30);

  # XXX pagination?
  return $self->_get_incidents(qw(triggered acknowledged))
    ->then(sub (@incidents) {
      my $pd_id = $self->pd_id_from_username($event->from_user->username);
      my @unresolved;

      for my $incident (@incidents) {
        # skip unacked incidents unless we've asked for all
        next if $only_acked && $incident->{status} eq 'triggered';

        # skip snoozed incidents (incidents with more than 30 minutes to unack)
        # if set
        if ($only_pending) {
          my ($unack_action) = grep {; $_->{type} eq "unacknowledge"} $incident->{pending_actions}->@*;
          my $unack_time = $ISO8601->parse_datetime($unack_action->{at});

          next if $unack_time > $pending_cutoff;
        }

        # 'resolve own' is 'resolve all the alerts I have acked'
        if ($whose eq 'own') {
          next unless grep {; $_->{acknowledger}{id} eq $pd_id }
                      $incident->{acknowledgements}->@*;
        }

        push @unresolved, $incident->{id};
      }

      unless (@unresolved) {
        $event->reply("Looks like there's no incidents to resolve. Lucky!");
        return Future->done;
      }

      $Logger->log([ "PagerDuty: resolving incidents: %s", \@unresolved ]);

      return $self->_update_status_for_incidents(
        $event->from_user,
        'resolved',
        \@unresolved,
      );
    })->then(sub (@incidents) {
      return Future->done if ! @incidents;

      my $n = @incidents;
      my $noun = $n == 1 ? 'incident' : 'incidents';

      my $exclamation = $whose eq 'all' ? "The board is clear!" : "Phew!";

      $event->reply("Successfully resolved $n $noun. $exclamation");
      return Future->done;
    })->else(sub (@failure) {
      $Logger->log(["PagerDuty error resolving incidents: %s", \@failure ]);
      $event->reply("Something went wrong resolving incidents. Sorry!");
    });
}

sub _check_at_oncall ($self) {
  my $channel = $self->oncall_channel;
  return unless $channel && $channel->isa('Synergy::Channel::Slack');

  $Logger->log("checking PagerDuty for oncall updates");

  return $self->_current_oncall_ids
    ->then(sub (@ids) {
      my @new = sort @ids;
      my @have = sort $self->oncall_list;

      if (join(',', @have) eq join(',', @new)) {
        $Logger->log("no changes in oncall list detected");
        return Future->done;
      }

      $Logger->log([ "will update oncall list; is now %s", join(', ', @new) ]);

      my @userids = map  {; $_->identity_for($channel->name) }
                    map  {; $self->hub->user_directory->user_named($_) }
                    grep {; defined }
                    map  {; $self->username_from_pd($_) }
                    @new;

      unless (@userids) {
        $Logger->log("could not convert PagerDuty oncall list into slack userids; ignoring");
        return Future->done;
      }

      my $f = $channel->slack->api_call(
        'usergroups.users.update',
        {
          usergroup => $self->oncall_group_address,
          users => join(q{,}, @userids),
        },
        privileged => 1,
      );

      $f->on_done(sub ($http_res) {
        my $data = decode_json($http_res->decoded_content);
        unless ($data->{ok}) {
          $Logger->log(["error updating oncall slack group: %s", $data]);
          return;
        }

        # Don't set our local cache until we're sure we've actually updated
        # the slack group; this way, if something goes wrong setting the group
        # the first time, we'll actually try again the next time around,
        # rather than just saying "oh, nothing changed, great!"
        $self->_set_oncall_list(\@new);
        $self->_announce_oncall_change(\@have, \@new);
      });

      return $f;
    })->retain;
}

sub _announce_oncall_change ($self, $before, $after) {
  return unless $self->oncall_change_announce_address;

  my %before = map {; ($self->username_from_pd($_) // $_) => 1 } $before->@*;
  my %after  = map {; ($self->username_from_pd($_) // $_) => 1 } $after->@*;

  my @leaving = grep { ! $after{$_} } keys %before;
  my @joining = grep { ! $before{$_} } keys %after;

  my @lines;

  if (@leaving) {
    my $verb = @leaving > 1 ? 'have' : 'has';
    my $removed = join ', ', sort @leaving;
    push @lines, "$removed $verb been removed from the oncall group.";
  }

  if (@joining) {
    my $verb = @joining > 1 ? 'have' : 'has';
    my $added = join ', ', sort @joining;
    push @lines, "$added $verb been added to the oncall group.";
  }

  my $oncall = join ', ', sort keys %after;
  push @lines, "Now oncall: $oncall";

  my $text = join qq{\n}, @lines;

  my @blocks = bk_richsection(bk_richtext($text))->as_struct;

  $self->_active_incidents_summary->then(sub ($summary = {}) {
    if (my $summary_text = delete $summary->{text}) {
      $text .= "\n$summary_text";
    }

    if (my $slack = delete $summary->{slack}) {
      push @blocks, { type => 'divider' };
      push @blocks, $slack->{blocks}->@*;
    }

    $self->oncall_channel->send_message(
      $self->oncall_change_announce_address,
      $text,
      {
        slack => {
          blocks => [ { type => 'rich_text', elements => \@blocks } ],
        },
      }
    );
  })->retain;
}

async sub _active_incidents_summary ($self) {
  my @incidents = await $self->_get_incidents(qw(triggered acknowledged));
  return unless @incidents;

  my $count = @incidents;
  my $title = sprintf("🚨 There %s %d %s on the board: 🚨",
    PL_V('is', $count),
    $count,
    PL_N('incident', $count)
  );

  my @text;

  my @bk_items;

  for my $incident (@incidents) {
    my $created = $ISO8601->parse_datetime($incident->{created_at});
    my $ago = ago(time - $created->epoch);

    my $notes = await $self->_get_incident_notes($incident->{id});

    my @notes_texts = map { $_->{content} } $notes->@*;

    push @text, " - #$incident->{incident_number} $incident->{description} (fired $ago)";

    my @notes_blocks;
    if (@notes_texts) {
      push @text, "   #$incident->{incident_number} notes: ";
      push @text, "   * " . join("\n   * ", @notes_texts);

      @notes_blocks = ("\nnotes: \n", "- ", join("\n- ", @notes_texts));
    }

    push @bk_items, bk_richsection(
      bk_link($incident->{html_url}, "#$incident->{incident_number}"),
      " (fired $ago): $incident->{description}",
      @notes_blocks,
    );

  }

  my $text = join qq{\n}, $title, @text;

  my $slack = {
    blocks => bk_blocks(
      bk_richblock(
        bk_richsection(bk_bold($title)),
        bk_ulist(@bk_items),
      )
    )->as_struct,
  };

  return { text => $text, slack => $slack };
}

sub _get_pd_account ($self, $token) {
  return $self->hub->http_get(
    $self->_url_for('/users/me'),
    Authorization => "Token token=$token",
    Accept        => 'application/vnd.pagerduty+json;version=2',
  )->then(sub ($res) {
    my $rc = $res->code;

    return Future->fail('That token seems invalid.')
      if $rc == 401;

    return Future->fail("Encountered error talking to LP: got HTTP $rc")
      unless $res->is_success;

    return Future->done(decode_json($res->decoded_content));
  })->retain;
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  after_set => async sub ($self, $username, $val) {
    $self->_clear_pd_to_slack_map;
    $self->_clear_slack_to_pd_map;
    return;
  },
  validator => async sub ($self, $value, @) {
    return (undef, 'user id cannot contain spaces') if $value =~ /\s/;
    return $value;
  },
);

__PACKAGE__->add_preference(
  name      => 'api-token',
  describer => async sub ($self, $value) { defined $value ? "<redacted>" : '<undef>' },
  default   => undef,
  validator => async sub ($self, $token, $event) {
    $token =~ s/^\s*|\s*$//g;

    my ($actual_val, $ret_err);

    $self->_get_pd_account($token)
      ->then(sub ($account) {
        $actual_val = $token;

        my $id = $account->{user}{id};
        my $email = $account->{user}{email};
        $event->reply(
          "Great! I found the PagerDuty user for $email, and will also set your PagerDuty user id to $id."
        );

        $self->set_user_preference($event->from_user, 'user-id', $id)->then(sub {
          Future->done
        });
      })
      ->else(sub ($err, @) {
        $ret_err = $err;
        return Future->fail('bad auth');
      })
      ->block_until_ready;

    return ($actual_val, $ret_err);
  },
);

__PACKAGE__->meta->make_immutable;

1;
