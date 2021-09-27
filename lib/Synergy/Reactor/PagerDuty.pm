use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::PagerDuty;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;

use Carp ();
use Data::Dumper::Concise;
use DateTime;
use DateTime::Format::ISO8601;
use DateTimeX::Format::Ago;
use Future;
use IO::Async::Timer::Periodic;
use JSON::MaybeXS qw(decode_json encode_json);
use List::Util qw(first);
use Synergy::Logger '$Logger';

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
has service_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# used for getting oncall names
has escalation_policy_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
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
  if ($self->oncall_channel && $self->oncall_group_address) {
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
      name      => 'maint-query',
      method    => 'handle_maint_query',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^maint(\s+status)?\s*$/in },
      help_entries => [
        # start /force is not documented here because it will mention itself to
        # the user when needed -- rjbs, 2020-06-15
        { title => 'maint', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
Conveniences for managing PagerDuty's "maintenance mode", aka "silence all the
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
        { title => 'oncall', text => '*oncall*: show a list of who is on call in PagerDuty right now' },
      ],
    },
    {
      name      => 'ack-all',
      method    => 'handle_ack_all',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^ack all\s*$/i },
      help_entries => [
        { title => 'ack', text => '*ack all*: acknowledge all triggered alerts in PagerDuty' },
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
*resolve*: manage resolving alerts in PagerDuty

You can run this in one of several ways:

• *resolve all*: resolve all triggered and acknowledged alerts in PagerDuty
• *resolve acked*: resolve the acknowledged alerts in PagerDuty
• *resolve mine*: resolve the acknowledged alerts assigned to you in PagerDuty
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

      # We only care if maint window covers a service we care about.
      my @relevant;
      for my $window (@$maint) {
        next unless grep {; $_->{id} eq $self->service_id } $window->{services}->@*;
        push @relevant, $window;
      }

      return Future->done(@relevant);
    });
}

sub _format_maints ($self, @maints) {
  return join q{; }, map {; $self->_format_maint_window($_) } @maints;
}

sub _format_maint_window ($self, $window) {
  state $ago_formatter = DateTimeX::Format::Ago->new(language => 'en');

  my $services = join q{, }, map {; $_->{summary} } $window->{services}->@*;
  my $start = $ISO8601->parse_datetime($window->{start_time});
  my $ago = $ago_formatter->format_datetime($start);
  my $who = $window->{created_by}->{summary};   # XXX map to our usernames

  return "$services ($ago, started by $who)";
}

sub handle_maint_query ($self, $event) {
  $event->mark_handled;

  my $f = $self->_relevant_maint_windows
    ->then(sub (@maints) {
      unless (@maints) {
        return $event->reply("PD not in maint right now. Everything is fine maybe!");
      }

      my $maint_text = $self->_format_maints(@maints);
      return $event->reply("🚨 PD in maint: $maint_text");
    })
    ->else(sub (@fails) {
      $Logger->log("PD handle_maint_query failed: @fails");
      return $event->reply("Something went wrong while getting maint state from PD. Sorry!");
    });

  $f->retain;
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
    ->else(sub ($message, $extra = {}) {
      return if $message eq 'not in maint';
      return if $message eq 'maint duration less than 30m';
      $Logger->log("PD error _check_long_maint():  $message");
    })->retain;
}

sub _current_oncall_ids ($self) {
  $self->_pd_request(GET => '/oncalls')
    ->then(sub ($data) {
      my $policy_id = $self->escalation_policy_id;
      my @oncall = map  {; $_->{user} }
                   grep {; $_->{escalation_policy}{id} eq $policy_id }
                   grep {; $_->{escalation_level} == 1}
                   $data->{oncalls}->@*;

      # XXX probably not generic enough
      my @ids = map {; $_->{id} } @oncall;
      return Future->done(@ids);
    });
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

sub handle_oncall ($self, $event) {
  $event->mark_handled;

  $self->_current_oncall_ids
    ->then(sub (@ids) {
        my @users = map {; $self->username_from_pd($_) // $_ } @ids;
        return $event->reply('current oncall: ' . join(', ', sort @users));
    })
    ->else(sub { $event->reply("I couldn't look up who's on call. Sorry!") })
    ->retain;
}

sub handle_maint_start ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

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
      return Future->fail('not-oncall');
    });
  }

  $f->then(sub {
    $self->_relevant_maint_windows
  })
  ->then(sub (@maints) {
    return Future->done unless @maints;

    my $desc = $self->_format_maints(@maints);
    $event->reply("PD already in maint: $desc");

    return Future->fail('already-maint');
  })
  ->then(sub {
    # XXX add reason here?
    return $self->_pd_request_for_user(
      $event->from_user,
      POST => '/maintenance_windows',
      {
        maintenance_window => {
          type => 'maintenance_window',
          start_time => $ISO8601->format_datetime(DateTime->now),
          end_time   =>  $ISO8601->format_datetime(DateTime->now->add(hours => 1)),
          services => [{
            id => $self->service_id,
            type => 'service_reference',
          }],
        },
      }
    );
  })
  ->then(sub ($data) {
    $self->_ack_all($event);
  })
  ->then(sub ($nacked) {
    my $ack_text = ' ';
    $ack_text = " 🚑 $nacked alert".($nacked > 1 ? 's' : '')." acked!"
      if $nacked;

    return $event->reply("🚨 PD now in maint for an hour!$ack_text Good luck!");
  })
  ->else(sub ($category, $extra = {}) {
    return if $category eq 'not-oncall';
    return if $category eq 'already-maint';

    $Logger->log("PD handle_maint_start failed: $category");
    return $event->reply("Something went wrong while fiddling with PD maint state. Sorry!");
  })
  ->retain;

  return;
}

sub handle_maint_end ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  my (@args) = split /\s+/, $event->text;

  $self->_relevant_maint_windows
    ->then(sub (@maints) {
      unless (@maints) {
        $event->reply("PD not in maint right now. Everything is fine maybe!");
        return Future->fail('no-maint');
      }

      # add 5s to allow for clock skew, otherwise PD gives you "end cannot be
      # before now"
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

      return Future->wait_all(@futures);
    })
    ->then(sub (@futures) {
      my @failed = grep {; $_->is_failed } @futures;

      if (@failed) {
        $Logger->log([ "PD demaint failed: %s", [ map {; $_->failure } @failed ] ]);
        $event->reply(
          "Something went wrong fiddling PD maint state; "
          . "you'll probably want to sort it out on the web. Sorry about that!"
        );
      } else {
        $event->reply("🚨 PD maint cleared. Good job everyone!");
      }
    })
    ->retain;
}

sub handle_ack_all ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_ack_all($event)
    ->then(sub ($n_acked) {
      my $noun = $n_acked == 1 ? 'incident' : 'incidents';
      $event->reply("Successfully acked $n_acked $noun. Good luck!");
    })
    ->else(sub {
      $event->reply("Something went wrong acking incidents. Sorry!");
    })
    ->retain;
}

# returns a future that yields a list of incidents
sub _get_incidents ($self, @statuses) {
  Carp::confess("no statuses found to get!") unless @statuses;

  # url params
  my $offset   = 0;
  my $limit    = 100;
  my $sid      = $self->service_id;
  my $statuses = join q{&}, map {; "statuses[]=$_" } @statuses;

  # iteration variables
  my $is_done = 0;
  my $i = 0;
  my @results;

  while (! $is_done) {
    my $url = "/incidents?service_ids[]=$sid&$statuses&limit=$limit&offset=$offset";

    $self->_pd_request(GET => $url)
      ->then(sub ($data) {
        push @results, $data->{incidents}->@*;

        $is_done = ! $data->{more};
        $offset += $limit;

        if (++$i > 20) {
          $Logger->log("did more than 20 requests getting incidents from PD; aborting to avoid infinite loop!");
          $is_done = 1;
        }
      })
      ->await;
  }

  return Future->done(@results);
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
  my $sid = $self->service_id;

  return $self->_get_incidents(qw(triggered))
    ->then(sub (@incidents) {
      my @unacked = map  {; $_->{id} } @incidents;
      $Logger->log([ "PD: acking incidents: %s", \@unacked ]);

      return $self->_update_status_for_incidents(
        $event->from_user,
        'acknowledged',
        \@unacked,
      );
    })->then(sub (@incidents) {
      return Future->done(scalar @incidents);
    });
}

sub handle_resolve_mine ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_resolve_incidents($event, {
    whose => 'own',
  })->retain;
}

sub handle_resolve_all ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_resolve_incidents($event, {
    whose => 'all',
  })->retain;
}

sub handle_resolve_acked ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_resolve_incidents($event, {
    whose => 'all',
    only_acked => 1,
  })->retain;
}

sub _resolve_incidents($self, $event, $arg) {
  my $sid = $self->service_id;

  my $whose = $arg->{whose};
  Carp::confess("_resolve_incidents called with bogus args")
    unless $whose && ($whose eq 'all' || $whose eq 'own');

  my $only_acked = $arg->{only_acked} // ($whose eq 'own' ? 1 : 0);

  # XXX pagination?
  return $self->_get_incidents(qw(triggered acknowledged))
    ->then(sub (@incidents) {
      my $pd_id = $self->pd_id_from_username($event->from_user->username);
      my @unresolved;

      for my $incident (@incidents) {
        # skip unacked incidents unless we've asked for all
        next if $only_acked && $incident->{status} eq 'triggered';

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

      $Logger->log([ "PD: acking incidents: %s", \@unresolved ]);

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
      $Logger->log(["PD error resolving incidents: %s", \@failure ]);
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
      my @have = sort $self->oncall_list->@*;

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

      $self->_announce_oncall_change(\@have, \@new)
        if $self->oncall_change_announce_address;

      return $f;
    })->retain;
}

sub _announce_oncall_change ($self, $old, $new) {
  my %before = map {; ($self->username_from_pd($_) // $_) => 1 } $old->@*;
  my %after = map {; ($self->username_from_pd($_) // $_) => 1 } $new->@*;

  my @leaving = grep { ! $after{$_} } keys %before;
  my @joining = grep { ! $before{$_} } keys %after;

  my @lines;

  if (@leaving) {
    my $verb = @leaving > 1 ? 'have' : 'has';
    my $removed = join ', ', sort @leaving;
    push @lines, "$removed $verb been removed from the oncall group";
  }

  if (@joining) {
    my $verb = @joining > 1 ? 'have' : 'has';
    my $added = join ', ', sort @joining;
    push @lines, "$added $verb been added to the oncall group";
  }

  my $oncall = join ', ', sort keys %after;
  push @lines, "Now oncall: $oncall";

  my $message = join "\n", @lines;
  $self->oncall_channel->send_message(
    $self->oncall_change_announce_address,
    $message,
  );
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
  after_set => sub ($self, $username, $val) {
    $self->_clear_pd_to_slack_map,
    $self->_clear_slack_to_pd_map,
  },
  validator => sub ($self, $value, @) {
    return (undef, 'user id cannot contain spaces') if $value =~ /\s/;
    return $value;
  },
);

__PACKAGE__->add_preference(
  name      => 'api-token',
  describer => sub ($value) { return defined $value ? "<redacted>" : '<undef>' },
  default   => undef,
  validator => sub ($self, $token, $event) {
    $token =~ s/^\s*|\s*$//g;

    my ($actual_val, $ret_err);

    $self->_get_pd_account($token)
      ->then(sub ($account) {
        $actual_val = $token;

        my $id = $account->{user}{id};
        my $email = $account->{user}{email};
        $event->reply(
          "Great! I found the PagerDuty user for $email, and will also set your PD user id to $id."
        );
        $self->set_user_preference($event->from_user, 'user-id', $id);

        return Future->done;
      })
      ->else(sub ($err) {
        $ret_err = $err;
        return Future->fail('bad auth');
      })
      ->block_until_ready;

    return ($actual_val, $ret_err);
  },
);

__PACKAGE__->meta->make_immutable;

1;
