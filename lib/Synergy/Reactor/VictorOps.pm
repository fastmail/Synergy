use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::VictorOps;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::HTTPEndpoint';

use experimental qw(signatures);
use namespace::clean;

use Crypt::Mac::HMAC qw( hmac_b64 );
use IO::Async::Timer::Periodic;
use JSON::MaybeXS;
use List::Util qw(first);
use DateTimeX::Format::Ago;
use Synergy::Logger '$Logger';
use Date::Parse 2.32;   # century time bugfix

has webhook_auth_code => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_webhook_auth_code',
);

has webhook_url => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_webhook_url',
);

has '+http_path' => (
  default => '/victorops',
);

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

  unless ($self->has_webhook_auth_code && $self->has_webhook_url) {
    # ¯\_(ツ)_/¯
    return [
      400,
      [ 'Content-Type', 'application/json' ],
      [ "{}\n" ],
    ];
  }

  # Create a string with the URL of the webhook, exactly how it appears in
  # VictorOps; this includes trailing slashes etc…
  my $to_hash   = $self->webhook_url;
  my $auth_code = $self->webhook_auth_code;

  # Sort the request’s POST variables alphabetically by key.
  #
  # Append each POST variable’s key and value to the URL string, with no
  # delimiter.
  my $param = $req->body_parameters;
  for my $key (sort keys $param->%*) {
    $to_hash .= "$key$param->{$key}";
  }

  # Create a binary hash of the resulting string with HMAC-SHA1, using the
  # webhook’s authentication key
  #
  # Base64 encode the binary signature
  my $hash = hmac_b64('SHA1', $auth_code, $to_hash);

  # Compare the output with the key X-VictorOps-Signature in the request – if
  # it matches, the request originated from VictorOps.
  unless ($hash eq $req->header('X-VictorOps-Signature')) {
    return [
      401,
      [ 'Content-Type', 'application/json' ],
      [ qq[{"error","authentication error"}\n] ],
    ];
  }

  $Logger->log([
    "successfully authenticated VictorOps incident posted: %s",
    { map {; $_ => $param->{$_} } keys %$param },
  ]);

  return [
    204,
    [],
    [],
  ];
}

has alert_endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  default => 'https://api.victorops.com/api-public/v1',
);

has api_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has team_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has _vo_to_slack_map => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  clearer => '_clear_vo_to_slack_map',
  handles => {
    username_from_vo => 'get',
  },
  default => sub ($self) {
    my %map;

    for my $sy_username (keys $self->user_preferences->%*) {
      my $vo_username = $self->get_user_preference($sy_username, 'username');
      $map{$vo_username} = $sy_username;
    }

    return \%map;
  },
);

has _slack_to_vo_map => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  clearer => '_clear_slack_to_vo_map',
  handles => {
    vo_from_username => 'get',
  },
  default => sub ($self) {
    my %map = reverse $self->_vo_to_slack_map->%*;
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

has maint_started_by_user => (
  is => 'rw',
  isa => 'Str',
  clearer => '_clear_maint_started_by_user',
);

has oncall_list => (
  is => 'ro',
  isa => 'ArrayRef',
  writer => '_set_oncall_list',
  lazy => 1,
  default => sub { [] },
);

around '_set_oncall_list' => sub ($orig, $self, @rest) {
  $self->$orig(@rest);
  $self->save_state;
};

sub start ($self) {
  if ($self->oncall_channel) {
    my $check_oncall_timer = IO::Async::Timer::Periodic->new(
      first_interval => 30,   # don't start immediately
      interval       => 150,
      on_tick        => sub { $self->_check_at_oncall },
    );

    $check_oncall_timer->start;
    $self->hub->loop->add($check_oncall_timer);

    # No maint warning timer unless we can warn oncall
    if ($self->oncall_group_address && $self->maint_warning_address) {
      my $maint_warning_timer = IO::Async::Timer::Periodic->new(
        first_interval => 45,
        interval => $self->maint_timer_interval,
        on_tick  => sub {  $self->_check_long_maint },
      );
      $maint_warning_timer->start;
      $self->hub->loop->add($maint_warning_timer);
    }
  }
}

sub listener_specs {
  return (
    {
      name      => 'alert',
      method    => 'handle_alert',
      exclusive => 1,
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^alert\s+/i },
      help_entries => [
        { title => 'alert', text => "*alert `TEXT`*: get help from staff on call" },
      ],
    },
    {
      name      => 'maint-query',
      method    => 'handle_maint_query',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^maint(\s+status)?\s*$/in },
      help_entries => [
        # start /force is not documented here because it will mention itself to
        # the user when needed -- rjbs, 2020-06-15
        { title => 'maint', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
Conveniences for managing VictorOps "maintenance mode", aka "silence all the
alerts because everything is on fire."

• *maint status*: show current maintenance state
• *maint start*: enter maintenance mode. All alerts are now silenced! Also acks
• *maint end*, *demaint*, *unmaint*, *stop*: leave maintenance mode. Alerts are noisy again!

When you leave maintenance mode, any alerts that happened during it, or even
shortly before it, will be marked resolved.  If you don't want that, say *maint
end /noresolve*
EOH
      ],
    },
    {
      name      => 'maint-start',
      method    => 'handle_maint_start',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ m{^maint\s+start\s*(/force)?\s*$}i },
    },
    {
      name      => 'maint-end',
      method    => 'handle_maint_end',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return 1 if $e->text =~ /^maint\s+(end|stop)\b/i;
        return 1 if $e->text =~ /^unmaint\b/i;
        return 1 if $e->text =~ /^demaint\b/i;
      },
    },
    {
      name      => 'oncall',
      method    => 'handle_oncall',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^oncall\s*$/i },
      help_entries => [
        { title => 'oncall', text => '*oncall*: show a list of who is on call in VictorOps right now' },
      ],
    },
    {
      name      => 'ack-all',
      method    => 'handle_ack_all',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^ack all\s*$/i },
      help_entries => [
        { title => 'ack', text => '*ack all*: acknowledge all triggered alerts in VictorOps' },
      ],
    },
    {
      name      => 'resolve-all',
      method    => 'handle_resolve_all',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ m{^resolve\s+all\s*$}i
      },
      help_entries => [
        { title => 'resolve', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
*resolve*: manage resolving alerts in VictorOps

You can run this in one of several ways:

• *resolve all*: resolve all triggered and acknowledged alerts in VictorOps
• *resolve acked*: resolve the acknowledged alerts in VictorOps
• *resolve mine*: resolve the acknowledged alerts assigned to you in VictorOps
EOH
      ],
    },
    {
      name      => 'resolve-acked',
      method    => 'handle_resolve_acked',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ m{^resolve\s+acked\s*$}i },
    },
    {
      name      => 'resolve-mine',
      method    => 'handle_resolve_mine',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ m{^resolve\s+mine\s*$}i },
    },
  );
}

sub state ($self) {
  return {
    oncall_list => $self->oncall_list,
    maint_started_by_user => $self->maint_started_by_user,
    last_maint_warning_time => $self->last_maint_warning_time,
  };
}

sub handle_alert ($self, $event) {
  $event->mark_handled;

  my $text = $event->text =~ s{^alert\s+}{}r;

  my $username = $event->from_user->username;

  # We don't use _vo_request here because this isn't an API call, and so uses
  # it own URI and doesn't need the headers!
  $self->hub->http_post(
    $self->alert_endpoint_uri,
    Content_Type  => 'application/json',
    Content       => encode_json({
      message_type  => 'CRITICAL',
      entity_id     => "synergy.via-$username",
      entity_display_name => "$text",
      state_start_time    => time,

      state_message => "$username has requested assistance through Synergy:\n$text\n",
    }),
  )->then(sub ($res) {
    return Future->fail('http') unless $res->is_success;

    $event->reply("I've sent the alert.  Good luck!");
  })->else(sub {
    $event->reply("I couldn't send this alert.  Sorry!");
  })->retain;
}

sub _vo_api_endpoint ($self, $endpoint) {
  return $self->api_endpoint_uri . $endpoint;
}

sub _vo_api_headers ($self) {
  return (
    'X-VO-Api-Id'  => $self->api_id,
    'X-VO-Api-Key' => $self->api_key,
    Accept         => 'application/json',
  );
}

sub _vo_request ($self, $method, $endpoint, $data = undef) {
  my %content;

  if ($data) {
    %content = (
      Content_Type => 'application/json',
      Content      => encode_json($data),
    );
  }

  return $self->hub->http_request(
    $method,
    $self->_vo_api_endpoint($endpoint),
    $self->_vo_api_headers,
    %content,
  )->then(sub ($res) {
    unless ($res->is_success) {
      my $code = $res->code;
      $Logger->log([ "error talking to VictorOps: %s", $res->as_string ]);
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

  if (my $who = $state->{maint_started_by_user}) {
    $self->maint_started_by_user($who);
  }

  if (my $when = $state->{last_maint_warning_time}) {
    $self->last_maint_warning_time($when);
  }
};

sub handle_maint_query ($self, $event) {
  $event->mark_handled;

  my $f = $self->_vo_request('GET' => '/maintenancemode')
    ->then(sub ($data) {
      my $maint = $data->{activeInstances} // [];
      unless (@$maint) {
        return $event->reply("VO not in maint right now. Everything is fine maybe!");
      }

      state $ago_formatter = DateTimeX::Format::Ago->new(language => 'en');

      # the way we use VO there's probably not more than one, but at least this
      # way if there are we won't just drop the rest on the floor -- robn, 2019-08-16
      my $maint_text = join ', ', map {
        my $start = DateTime->from_epoch(epoch => int($_->{startedAt} / 1000));
        my $ago = $ago_formatter->format_datetime($start);
        "$ago by $_->{startedBy}"
      } @$maint;

      return $event->reply("🚨 VO in maint: $maint_text");
    })
    ->else(sub (@fails) {
      $Logger->log("VO: handle_maint_query failed: @fails");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    });

  $f->retain;
}

sub handle_resolve_mine ($self, $event) {
  $event->mark_handled;
  $self->_resolve_incidents($event, {
    type => 'acked',
    whose => 'own'
  })->retain;
}

sub handle_resolve_all ($self, $event) {
  $event->mark_handled;
  $self->_resolve_incidents($event, {
    type => 'all',
    whose => 'all'
  })->retain;
}

sub handle_resolve_acked ($self, $event) {
  $event->mark_handled;
  $self->_resolve_incidents($event, {
    type => 'acked',
    whose => 'all'
  })->retain;
}

sub _check_long_maint ($self) {
  my $current_time = time();
  # No warning if we've warned in last 25 minutes
  return unless ($current_time - $self->last_maint_warning_time) > (60 * 25);

  $self->_vo_request(GET => '/maintenancemode')
  ->then(sub ($data) {
    my $maint = $data->{activeInstances} // [];
    unless (@$maint) {
      $self->_clear_maint_started_by_user();
      $self->save_state;
      return Future->fail('not in maint');
    }

    $self->last_maint_warning_time($current_time);
    $self->save_state;

    # maint startedAt is unix time * 1000
    my $maint_start_time = int($maint->[0]->{startedAt} / 1000);
    my $maint_duration_s = $current_time - $maint_start_time;
    return Future->fail('maint duration less than 30m')
      unless $maint_duration_s > (60 * 30);

    my $group_address = $self->oncall_group_address;
    my $maint_duration_m = int($maint_duration_s / 60);
    my $who = $maint->[0]->{startedBy} eq 'PUBLICAPI'
            ? $self->maint_started_by_user
            : $self->_vo_to_slack_map->{$maint->[0]->{startedBy}};

    my $text = "Hey, by the way, VictorOps is in maintenance mode."
             . " (Started $maint_duration_m minutes ago by $who.)";

    $self->oncall_channel->send_message(
      $self->maint_warning_address,
      "\@oncall $text",
      { slack => "<!subteam^$group_address> $text" }
    );
  })
  ->else(sub ($message, $extra = {}) {
    return if $message eq 'not in maint';
    return if $message eq 'maint duration less than 30m';
    $Logger->log("VO: error _check_long_maint():  $message");
  })->retain;
}

sub _current_oncall_names ($self) {
  $self->_vo_request(GET => '/oncall/current')
    ->then(sub ($data) {
      my ($team) = grep {; $_->{team}{slug} eq $self->team_name } $data->{teamsOnCall}->@*;

      return Future->fail('no team') unless $team;

      # XXX probably not generic enough
      my @names = map {; $_->{onCalluser}{username} } $team->{oncallNow}[0]{users}->@*;
      return Future->done(@names);
    });
}

# This returns a Future that, when done, gives a boolean as to whether or not
# $who is oncall right now.
sub _user_is_oncall ($self, $who) {
  return $self->_current_oncall_names
    ->then(sub (@names) {
      my $want_name = $self->get_user_preference($who->username, 'username')
                   // $who->username;
      return Future->done(!! first { $_ eq $want_name } @names)
    });
}

sub handle_oncall ($self, $event) {
  $event->mark_handled;

  $self->_current_oncall_names
    ->then(sub (@names) {
        my @users = map {; $self->username_from_vo($_) // $_ } @names;
        return $event->reply('current oncall: ' . join(', ', sort @users));
    })
    ->else(sub { $event->reply("I couldn't look up who's on call. Sorry!") })
    ->retain;
}

sub handle_maint_start ($self, $event) {
  $event->mark_handled;

  my $force = $event->text =~ m{/force\s*$};
  my $f;

  if ($force) {
    # don't bother checking
    $f = Future->done;
  } else {
    $f = $self->_user_is_oncall($event->from_user)->then(sub ($is_oncall) {
      return Future->done if $is_oncall;

      $event->error_reply(join(q{ },
        "You don't seem to be on call right now.",
        "Usually, the person oncall is getting the alerts, so they should be",
        "the one to decide whether or not to shut them up.",
        "If you really want to do this, try again with /force."
      ));
      return Future->fail('not oncall');
    });
  }

  $f->then(sub {
    return $self->_vo_request(POST => '/maintenancemode/start', {
      names => [], # nothing, global mode
    });
  })
  ->then(sub ($data) {
    $self->maint_started_by_user($event->from_user->username);
    $self->save_state;
    $self->_ack_all($event->from_user->username);
  })
  ->then(sub ($nacked) {
    my $ack_text = ' ';
    $ack_text = " 🚑 $nacked alert".($nacked > 1 ? 's' : '')." acked!"
      if $nacked;

    return $event->reply("🚨 VO now in maint!$ack_text Good luck!");
  })
  ->else(sub ($category, $extra = {}) {
    return if $category eq 'not oncall';

    if ($category eq 'http') {
      my $res = $extra->{http_res};

      # Special-case "we're already in maint"
      if ($res->code == 409) {
        $event->reply("VO already in maint!");
        return Future->done;
      }
    }

    $Logger->log("VO: handle_maint_start failed: $category");
    return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
  })
  ->retain;

  return;
}

sub _resolve_incidents($self, $event, $args) {
  my $silent_if_none = $args->{silent_if_none};

  return $self->_vo_request(GET => '/incidents')
    ->then(sub ($data) {
      my $vo_username = $self->vo_from_username($event->from_user->username);
      my @unresolved;

      for my $incident ($data->{incidents}->@*) {
        next if $incident->{currentPhase} eq 'RESOLVED';
        # only resolve incidents paged to our team
        next unless grep { $_ eq $self->team_name } $incident->{pagedTeams}->@*;

        if (my $since = $args->{since}) {
          next unless (str2time($incident->{startTime}) * 1000) > $since;
        }

        unless ($args->{type} eq 'all') {
          # skip unacked incidents unless we've asked for all
          next unless $incident->{currentPhase} eq 'ACKED';
        }

        if ($args->{whose} eq 'own' && $args->{type} ne 'all') {
          next unless $incident->{transitions}[-1]->{by} eq $vo_username;
        }

        push @unresolved, $incident->{incidentNumber};
      }

      unless (@unresolved) {
        $event->reply("Looks like there's no incidents to resolve. Lucky!")
          unless $silent_if_none;

        return Future->done({ no_incidents => 1 });  # hack
      }

      return $self->_vo_request(PATCH => "/incidents/resolve", {
        userName => $vo_username,
        incidentNames => \@unresolved,
      });
    })->then(sub ($data) {
      return Future->done(0) if $data->{no_incidents};

      my $n = $data->{results}->@*;
      my $noun = $n == 1 ? 'incident' : 'incidents';

      my $exclamation = $args->{whose} eq 'all' ? "The board is clear!" : "Phew!";

      $event->reply("Successfully resolved $n $noun. $exclamation");
      return Future->done(0)
    })->else(sub {
      $event->reply("Something went wrong resolving incidents. Sorry!");
    });
}

sub handle_maint_end ($self, $event) {
  $event->mark_handled;

  my (@args) = split /\s+/, $event->text;

  my $f = $self->_vo_request(GET => '/maintenancemode')
    ->then(sub ($data) {
      my $maint = $data->{activeInstances} // [];
      unless (@$maint) {
        $event->reply("VO not in maint right now. Everything is fine maybe!");
        return Future->fail('no maint');
      }

      my ($global_maint) = grep { $_->{isGlobal} } @$maint;
      unless ($global_maint) {
        $event->reply(
          "I couldn't find the VO global maint, but there were other maint modes set. ".
          "This isn't something I know how to deal with. ".
          "You'll need to go and sort it out in the VO web UI.");
        return Future->fail('no maint');
      }

      my $timestamp = $maint->[0]->{startedAt};
      my $instance_id = $global_maint->{instanceId};

      return Future->done($timestamp, $instance_id);
    })
    ->then(sub ($timestamp, $instance_id) {
      if (grep {; $_ =~ qr{\A/nor(?:esolve)?\z} } @args) {
        return Future->done($instance_id);
      }

      # We resolve before demainting because there's a race: if you exit
      # maint, VO immediately sends phone alerts for everything that's active,
      # even if they're going to be resolved in a quarter-second. That's
      # really annoying, so we resolve everything, then tell VO to stop maint,
      # at which point there shouldn't be anything left to buzz.
      return $self->_resolve_incidents($event, {
        type => 'all',
        since => $timestamp - 600000,
        whose => 'all',
        silent_if_none => 1,
      })->transform(done => sub { $instance_id });
    })
    ->then(sub ($instance_id) {
      return $self->_vo_request(PUT => "/maintenancemode/$instance_id/end");
    })
    ->then(sub {
      $self->_clear_maint_started_by_user();
      return $event->reply("🚨 VO maint cleared. Good job everyone!");
    }
    )->else(sub ($category, $extra = {}) {
      return if $category eq 'no maint';

      if ($category eq 'http') {
        $event->reply("I couldn't clear the VO maint state. Sorry!");
        return Future->done;
      }

      $Logger->log("VO: handle_maint_end failed: $category");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    });

  $f->retain;
}

sub handle_ack_all ($self, $event) {
  $event->mark_handled;

  $self->_ack_all($event->from_user->username)
    ->then(sub ($n_acked) {
      my $noun = $n_acked == 1 ? 'incident' : 'incidents';
      $event->reply("Successfully acked $n_acked $noun. Good luck!");
    })
    ->else(sub {
      $event->reply("Something went wrong acking incidents. Sorry!");
    })
    ->retain;
}

sub _ack_all ($self, $username) {
  return $self->_vo_request(GET => '/incidents')
    ->then(sub ($data) {
      my @unacked = map  {; $_->{incidentNumber} }
                    grep {; $_->{currentPhase} eq 'UNACKED' }
                    $data->{incidents}->@*;

      return Future->done({ results => [] }) unless @unacked;

      $Logger->log("VO: acking incidents: @unacked");

      return $self->_vo_request(PATCH => '/incidents/ack', {
        userName => $self->vo_from_username($username),
        incidentNames => \@unacked,
      });
    })->then(sub ($data) {
      # XXX something smarter here?
      my $nacked = $data->{results}->@*;
      return Future->done($nacked);
    });
}


sub _check_at_oncall ($self) {
  my $channel = $self->oncall_channel;
  return unless $channel && $channel->isa('Synergy::Channel::Slack');

  $Logger->log("checking VO for oncall updates");

  return $self->_current_oncall_names
    ->then(sub (@names) {
      my @new = sort @names;
      my @have = sort $self->oncall_list->@*;

      if (join(',', @have) eq join(',', @new)) {
        $Logger->log("no changes in oncall list detected");
        return Future->done;
      }

      $Logger->log([ "will update oncall list; is now %s", join(', ', @new) ]);

      my @userids = map  {; $_->identity_for($channel->name) }
                    map  {; $self->hub->user_directory->user_named($_) }
                    grep {; defined }
                    map  {; $self->username_from_vo($_) }
                    @new;

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
      });

      return $f;
    })->retain;
}

__PACKAGE__->add_preference(
  name      => 'username',
  after_set => sub ($self, $username, $val) {
    $self->_clear_vo_to_slack_map,
    $self->_clear_slack_to_vo_map,
  },
  validator => sub ($self, $value, @) {
    return (undef, 'username cannot contain spaces') if $value =~ /\s/;

    return lc $value;
  },
);

1;
