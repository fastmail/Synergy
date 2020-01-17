use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::VictorOps;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;
use JSON::MaybeXS;
use List::Util qw(first);
use DateTimeX::Format::Ago;
use Synergy::Logger '$Logger';

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

sub listener_specs {
  return (
    {
      name      => 'alert',
      method    => 'handle_alert',
      exclusive => 1,
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^alert\s+/i },
      help_entries => [
        { title => 'alert', text => "alert TEXT: get help from staff on call" },
      ],
    },
    {
      name      => 'maint-query',
      method    => 'handle_maint_query',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^maint(\s+status)?\s*$/in },
      help_entries => [
        { title => 'maint', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
Conveniences for managing VictorOps "maintenance mode", aka "silence all the
alerts because everything is on fire."

• *maint*, *maint status*: show current maintenance state
• *maint start*: enter maintenance mode. All alerts are now silenced! Also acks all unacked alerts, ain't no one got time for that.
• *maint end*, *demaint*, *unmaint*, *stop*: leave maintenance mode. Alerts are noisy again!
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
        return 1 if $e->text =~ /^maint\s+(end|stop)\s*$/i;
        return 1 if $e->text =~ /^unmaint\s*$/i;
        return 1 if $e->text =~ /^demaint\s*$/i;
      },
    },
    {
      name      => 'oncall',
      method    => 'handle_oncall',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^oncall\s*$/i },
    },
  );
}

sub handle_alert ($self, $event) {
  $event->mark_handled;

  my $text = $event->text =~ s{^alert\s+}{}r;

  my $username = $event->from_user->username;

  my $future = $self->hub->http_post(
    $self->alert_endpoint_uri,
    async => 1,
    Content_Type  => 'application/json',
    Content       => encode_json({
      message_type  => 'CRITICAL',
      entity_id     => "synergy.via-$username",
      entity_display_name => "$text",
      state_start_time    => time,

      state_message => "$username has requested assistance through Synergy:\n$text\n",
    }),
  );

  $future->on_fail(sub {
    $event->reply("I couldn't send this alert.  Sorry!");
  });

  $future->on_ready(sub {
    $event->reply("I've sent the alert.  Good luck!");
  });

  return;
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

sub state ($self) {
  return {
    preferences => $self->user_preferences,
  };
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }
  }
};

sub handle_maint_query ($self, $event) {
  $event->mark_handled;

  my $f = $self->hub->http_get(
    $self->_vo_api_endpoint('/maintenancemode'),
    $self->_vo_api_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log("VO: get maintenancemode failed: ".$res->as_string);
        return $event->reply("I couldn't look up VO maint state. Sorry!");
      }

      my $data = decode_json($res->content);
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
    }
  )->else(
    sub (@fails) {
      $Logger->log("VO: handle_maint_query failed: @fails");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    }
  );

  $f->retain;
}

sub _current_oncall_names ($self) {
  return $self->hub->http_get(
    $self->_vo_api_endpoint('/oncall/current'),
    $self->_vo_api_headers,
    async => 1,
  )
  ->then(sub ($http_res) {
    unless ($http_res->is_success) {
      $Logger->log("VO: get oncall failed: " . $http_res->as_string);
      return Future->fail('http get');
    }

    my $data = decode_json($http_res->content);
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
    return $self->hub->http_post(
      $self->_vo_api_endpoint('/maintenancemode/start'),
      $self->_vo_api_headers,
      async => 1,
      Content_Type => 'application/json',
      Content      => encode_json( { names => [] } ), # nothing, global mode
    );
  })
  ->then(sub ($res) {
    if ($res->code == 409) {
      return $event->reply("VO already in maint!");
    }

    unless ($res->is_success) {
      $Logger->log("VO: post maint failed: ".$res->as_string);
      return $event->reply("I couldn't start maint. Sorry!");
    }

    $self->_ack_all($event->from_user->username);
  })
  ->then(sub ($nacked) {
    my $ack_text = ' ';
    $ack_text = " 🚑 $nacked alert".($nacked > 1 ? 's' : '')." acked!"
      if $nacked;
    return $event->reply("🚨 VO now in maint!$ack_text Good luck!");
  })
  ->else(sub (@fails) {
    return if $fails[0] eq 'not oncall';

    $Logger->log("VO: handle_maint_start failed: @fails");
    return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
  })
  ->retain;

  return;
}

sub handle_maint_end ($self, $event) {
  $event->mark_handled;

  my $f = $self->hub->http_get(
    $self->_vo_api_endpoint('/maintenancemode'),
    $self->_vo_api_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log("VO: get maintenancemode failed: ".$res->as_string);
        return $event->reply("I couldn't look up the current VO maint state. Sorry!");
      }

      my $data = decode_json($res->content);
      my $maint = $data->{activeInstances} // [];
      unless (@$maint) {
        $event->reply("VO not in maint right now. Everything is fine maybe!");
        return Future->fail('no maint');
      }

      my ($global_maint) = grep { $_->{isGlobal} } @$maint;
      unless ($global_maint) {
        return $event->reply(
          "I couldn't find the VO global maint, but there were other maint modes set. ".
          "This isn't something I know how to deal with. ".
          "You'll need to go and sort it out in the VO web UI.");
      }

      my $instance_id = $global_maint->{instanceId};

      return $self->hub->http_put(
        $self->_vo_api_endpoint("/maintenancemode/$instance_id/end"),
        $self->_vo_api_headers,
        async => 1,
      );
    }
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log("VO: put maintenancemode failed: ".$res->as_string);
        return $event->reply("I couldn't clear the VO maint state. Sorry!");
      }

      return $event->reply("🚨 VO maint cleared. Good job everyone!");
    }
  )->else(
    sub (@fails) {
      return if $fails[0] eq 'no maint';
      $Logger->log("VO: handle_maint_end failed: @fails");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    }
  );

  $f->retain;
}

sub _ack_all ($self, $username) {
  my $f = $self->hub->http_get(
    $self->_vo_api_endpoint('/incidents'),
    $self->_vo_api_headers,
    async => 1,
  )
  ->then(sub ($res) {
    unless ($res->is_success) {
      $Logger->log("VO: get incidents failed: ".$res->as_string);
      return Future->fail('get incidents');
    }

    my $data = decode_json($res->content);
    my @unacked =
      map { $_->{currentPhase} eq 'UNACKED' ? $_->{incidentNumber} : () }
      $data->{incidents}->@*;

    return Future->done(0) unless @unacked;

    $Logger->log("VO: acking incidents: @unacked");

    $self->hub->http_patch(
      $self->_vo_api_endpoint('/incidents/ack'),
      $self->_vo_api_headers,
      async => 1,
      Content_Type => 'application/json',
      Content => encode_json({
        userName => $self->vo_from_username($username),
        incidentNames => \@unacked,
      }),
    );
  })->then(sub ($res) {
    return Future->done($res) unless ref $res;

    unless ($res->is_success) {
      $Logger->log("VO: ack incidents failed: ".$res->as_string);
      return Future->fail('ack incidents');
    }

    my $data = decode_json($res->content);
    my $nacked = $data->{results}->@*;

    return Future->done($nacked);
  });
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
