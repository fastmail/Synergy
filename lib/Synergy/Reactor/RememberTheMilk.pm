use v5.32.0;
use warnings;
use utf8;
package Synergy::Reactor::RememberTheMilk;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use JSON::MaybeXS;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Try::Tiny;
use WebService::RTM::CamelMilk;

my $JSON = JSON::MaybeXS->new->utf8->canonical;

has [ qw( api_key api_secret ) ] => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has rtm_client => (
  is    => 'ro',
  lazy  => 1,
  default => sub ($self, @) {
    WebService::RTM::CamelMilk->new({
      api_key     => $self->api_key,
      api_secret  => $self->api_secret,
      http_client => $self->hub->http_client,
    });
  },
);

has timelines => (
  reader  => '_timelines',
  lazy    => 1,
  default => sub {  {}  },
);

sub timeline_for ($self, $user) {
  return unless my $token = $self->get_user_preference($user, 'api-token');

  my $username = $user->username;

  my $store = $self->_timelines;
  my $have  = $store->{$username};

  # Here is the intent:  if three things running at once all ask for a
  # timeline id, we should only create one.  So, if we have an answer, great,
  # this is a cache.  If we have a pending future, great, everything can
  # sequence on the same attempt to get a timeline, because having one is
  # sufficient.  If we had one trying before, though, and it failed, we should
  # clear it, because we can try again.  Maybe eventually we want a rate limit,
  # here.  For now, whatever. -- rjbs, 2019-08-06
  return $have if $have && ($have->is_done || ! $have->is_ready);
  delete $store->{$username};

  my $rsp_f = $self->rtm_client->api_call('rtm.timelines.create' => {
    auth_token => $token,
  });

  return $store->{$username} = $rsp_f->then(sub ($rsp) {
    unless ($rsp->is_success) {
      $Logger->log([ "failed to create a timeline: %s", $rsp->_response ]);
      return Future->fail("couldn't get timeline");
    }

    return Future->done($rsp->get('timeline'));
  });
}

has pending_frobs => (
  reader  => '_pending_frobs',
  lazy    => 1,
  default => sub {  {}  },
);

sub frob_for ($self, $user) {
  return Future->fail('unknown user')
    unless $user;

  return Future->fail('already enrolled')
    if $self->user_has_preference($user, 'api-token');

  my $username = $user->username;

  my $store = $self->_pending_frobs;
  my $have  = $store->{$username};

  # This is just the timeline generator code, copied and pasted.
  return $have if $have && ($have->is_done || ! $have->is_ready);
  delete $store->{$username};

  my $rsp_f = $self->rtm_client->api_call('rtm.auth.getFrob' => {});

  return $store->{$username} = $rsp_f->then(sub ($rsp) {
    unless ($rsp->is_success) {
      $Logger->log([ "failed to get a frob: %s", $rsp->_response ]);
      return Future->fail("couldn't get frob");
    }

    return Future->done($rsp->get('frob'));
  });
}

command todo => {
  help => '*todo `create-string`*: Given an RTM "quick create" string, this makes a new task.',
} => async sub ($self, $event, $todo) {
  return await $event->error_reply("I don't have an RTM auth token for you.")
    unless my $token = $self->get_user_preference($event->from_user, 'api-token');

  return await $event->error_reply("You didn't tell me what you want to do!")
    unless length $todo;

  my $error_reply;
  my $ok = eval {
    my $tl = await $self->timeline_for($event->from_user);

    my $rsp = await $self->rtm_client->api_call('rtm.tasks.add' => {
      auth_token => $token,
      timeline   => $tl,
      name  => $todo,
      parse => 1,
    });

    unless ($rsp->is_success) {
      $Logger->log([
        "failed to cope with a request to make a task: %s", $rsp->_response,
      ]);
      $error_reply = $event->error_reply("Something went wrong creating that task, sorry.");
      die $rsp->_response;
    }

    $Logger->log([ "made task: %s", $rsp->_response ]);
    1;
  };

  if ($ok) {
    return await $event->reply("Task created!");
  }

  my $error = $@;
  $Logger->log([ "failed to make task: %s", $error ]);
  $error_reply //= $event->error_reply("Something went wrong creating that task, sorry.");
  return await $event->reply("Sorry, something went wrong making that task.");
};

command milk => {
  help => '*milk [`filter`]*: list all your tasks; default filter is "status:incomplete"'
} => async sub ($self, $event, $filter) {
  return await $event->error_reply("I don't have an RTM auth token for you.")
    unless my $token = $self->get_user_preference($event->from_user, 'api-token');

  my $rsp = await $self->rtm_client->api_call('rtm.tasks.getList' => {
    auth_token => $token,
    filter     => $filter || 'status:incomplete',
  });

  unless ($rsp->is_success) {
    $Logger->log([
      "failed to cope with a request for milk: %s", $rsp->_response,
    ]);
    return await $event->reply("Something went wrong getting that milk, sorry.");
  }

  # The structure is:
  # { tasks => {
  #   list  => [ { id => ..., taskseries => [ { name => ..., task => [ {}
  my @lines;
  for my $list ($rsp->get('tasks')->{list}->@*) {
    for my $tseries ($list->{taskseries}->@*) {
      my @tasks = $tseries->{task}->@*;
      push @lines, map {; +{
        string => sprintf('%s %s — %s',
          ($_->{completed} ? '✓' : '•'),
          $tseries->{name},
          ($_->{due} ? "due $_->{due}" : "no due date")),
        due    => $_->{due},
        added  => $_->{added},
      } } @tasks;

      last if @lines >= 10;
    }
  }

  return await $event->reply("No tasks found!") unless @lines;

  @lines = sort { ($a->{due}||9) cmp ($b->{due}||9)
              ||  $a->{added} cmp $b->{added} } @lines;

  $#lines = 9 if @lines > 10;

  return await $event->reply(join qq{\n},
    "*Tasks found:*",
    map {; $_->{string} } @lines
  );
};

command milkauth => {
  help => '*milkauth*: authorize Synergy to act as an RTM client for you',
} => async sub ($self, $event, $arg) {
  my $user = $event->from_user;

  if ($self->user_has_preference($user, 'api-token')) {
    return await $event->error_reply("It looks like you've already authenticated!");
  }

  $arg //= 'start';
  unless ($arg eq 'start' or $arg eq 'complete') {
    return await $event->error_reply("You need to say either `milkauth start` or `milkauth complete`.");
  }

  if ($arg eq 'start') {
    my $reply = eval {
      my $frob = await $self->frob_for($event->from_user);
      my $auth_uri = join q{?},
        "https://www.rememberthemilk.com/services/auth/",
        $self->rtm_client->_signed_content({ frob => $frob, perms => 'write' });

      my $text = <<~"END";
      To authorize me to talk to RTM for you, follow this link: $auth_uri

      …and then tell me `milkauth complete`
      END

      return $event->private_reply($text, { slack => $text });
    };

    if ($reply) {
      return await $reply;
    }

    my $error = $@;
    $Logger->log([ "failed to make start auth: %s", $error ]);
    return await $event->reply("Sorry, something went wrong!");
  }

  # So we must have 'auth complete'
  my $frob_f = $self->frob_for($event->from_user);

  return $event->reply("You're not ready to complete auth yet!")
    unless $frob_f->is_ready;

  my $frob = await $frob_f;

  my $rsp  = await $self->rtm_client->api_call(
    'rtm.auth.getToken' => { frob => $frob }
  );

  unless ($rsp->is_success) {
    $Logger->log([ "error getting token: %s", $rsp->_response ]);
    return await $event->reply("Remember The Milk rejected our request to get a token!");
  }

  my $token = $rsp->get('auth')->{token};

  my $got = await $self->set_user_preference($user, 'api-token', $token);

  return await $event->reply("You're authenticated!");
};

__PACKAGE__->add_preference(
  name      => 'api-token',
  validator => async sub ($self, $value, @) {
    return (undef, "You can only set your API token with the milkauth command.")
      if defined $value;

    return (undef, undef);
  },
  describer => async sub ($self, $v) { defined $v ? "<redacted>" : '<undef>' },
  default   => undef,
);

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

1;
