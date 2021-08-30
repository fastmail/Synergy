use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::PagerDuty;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;

use Data::Dumper::Concise;
use DateTime::Format::ISO8601;
use DateTimeX::Format::Ago;
use IO::Async::Timer::Periodic;
use JSON::MaybeXS qw(decode_json encode_json);
use List::Util qw(first);
use Synergy::Logger '$Logger';

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
    pd_from_username => 'get',
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
      name      => 'oncall',
      method    => 'handle_oncall',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^oncall\s*$/i },
      help_entries => [
        { title => 'oncall', text => '*oncall*: show a list of who is on call in PagerDuty right now' },
      ],
    },
  );
}

sub state ($self) {
  return {
    oncall_list => $self->oncall_list,
  };
}

sub _url_for ($self, $endpoint) {
  return $self->api_endpoint_uri . $endpoint;
}

sub _pd_request ($self, $method, $endpoint, $data = undef) {
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
    Authorization => 'Token token=' . $self->api_key,
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
};

sub handle_maint_query ($self, $event) {
  $event->mark_handled;

  my $f = $self->_pd_request('GET' => '/maintenance_windows')
    ->then(sub ($data) {
      my $maint = $data->{maintenance_windows} // [];

      # We only care if maint window covers a service we care about.
      my @relevant;
      for my $window (@$maint) {
        next unless grep {; $_->{id} eq $self->service_id } $window->{services}->@*;
        push @relevant, $window;
      }

      unless (@relevant) {
        return $event->reply("PD not in maint right now. Everything is fine maybe!");
      }

      state $ago_formatter = DateTimeX::Format::Ago->new(language => 'en');

      # the way we use VO there's probably not more than one, but at least this
      # way if there are we won't just drop the rest on the floor -- robn, 2019-08-16
      my @texts;
      for my $window (@relevant) {
        my $services = join q{, }, map {; $_->{summary} } $window->{services}->@*;
        my $start = DateTime::Format::ISO8601->parse_datetime($window->{start_time});
        my $ago = $ago_formatter->format_datetime($start);
        my $who = $window->{created_by}->{summary};   # XXX map to our usernames

        push @texts, "$services ($ago, started by $who)";
      }

      my $maint_text = join q{; }, @texts;
      return $event->reply("🚨 PD in maint: $maint_text");
    })
    ->else(sub (@fails) {
      $Logger->log("PD handle_maint_query failed: @fails");
      return $event->reply("Something went wrong while getting maint state from PD. Sorry!");
    });

  $f->retain;
}

sub _current_oncall_ids ($self) {
  $self->_pd_request(GET => '/oncalls')
    ->then(sub ($data) {
      my @oncall = map {; $_->{user} }
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

      return $f;
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

__PACKAGE__->meta->make_immutable;

1;
