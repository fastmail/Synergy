use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::RememberTheMilk;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;

use JSON::MaybeXS;
use Synergy::Logger '$Logger';
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

sub listener_specs {
  return (
    {
      name      => 'milk',
      method    => 'handle_milk',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Amilk(?:\s|\z)/
      },
    },
    {
      name      => 'todo',
      method    => 'handle_todo',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Atodo(?:\s|\z)/
      },
    },
    {
      name      => 'auth',
      method    => 'handle_auth',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Amilkauth(?:\s|\z)/i
      },
    },
  );
}

sub handle_todo ($self, $event) {
  $event->mark_handled;

  my (undef, $todo) = split /\s+/, $event->text, 2;

  return $event->error_reply("I don't have an RTM auth token for you.")
    unless my $token = $self->get_user_preference($event->from_user, 'api-token');

  return $event->error_reply("You didn't tell me what you want to do!")
    unless length $todo;

  my $tl_f = $self->timeline_for($event->from_user);

  $tl_f->then(sub ($tl) {
    my $rsp_f = $self->rtm_client->api_call('rtm.tasks.add' => {
      auth_token => $token,
      timeline   => $tl,
      name  => $todo,
      parse => 1,
    });

    $rsp_f->then(sub ($rsp) {
      unless ($rsp->is_success) {
        $Logger->log([
          "failed to cope with a request to make a task: %s", $rsp->_response,
        ]);
        return $event->reply("Something went wrong creating that task, sorry.");
      }

      $Logger->log([ "made task: %s", $rsp->_response ]);
      return $event->reply("Task created!");
    });
  })->else(sub (@fail) {
    $Logger->log([ "failed to make task: %s", \@fail ]);
    $event->reply("Sorry, something went wrong making that task.");
  })->retain;
}

sub handle_milk ($self, $event) {
  $event->mark_handled;

  my (undef, $filter) = split /\s+/, $event->text, 2;

  return $event->error_reply("I don't have an RTM auth token for you.")
    unless my $token = $self->get_user_preference($event->from_user, 'api-token');

  my $rsp_f = $self->rtm_client->api_call('rtm.tasks.getList' => {
    auth_token => $token,
    filter     => $filter || 'status:incomplete',
  });

  $rsp_f->then(sub ($rsp) {
    unless ($rsp->is_success) {
      $Logger->log([
        "failed to cope with a request for milk: %s", $rsp->_response,
      ]);
      return $event->reply("Something went wrong getting that milk, sorry.");
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

    $event->reply("No tasks found!") unless @lines;

    @lines = sort { ($a->{due}||9) cmp ($b->{due}||9)
                ||  $a->{added} cmp $b->{added} } @lines;

    $#lines = 9 if @lines > 10;

    $event->reply(join qq{\n},
      "*Tasks found:*",
      map {; $_->{string} } @lines
    );
  })->retain;
}

sub handle_auth ($self, $event) {
  $event->mark_handled;
  my (undef, $arg) = split /\s+/, lc $event->text, 2;

  my $user = $event->from_user;

  if ($self->user_has_preference($user, 'api-token')) {
    return $event->error_reply("It looks like you've already authenticated!");
  }

  $arg //= 'start';
  unless ($arg eq 'start' or $arg eq 'complete') {
    return $event->error_reply("You need to say either `milkauth start` or `milkauth complete`.");
  }

  if ($arg eq 'start') {
    return $self->frob_for($event->from_user)
      ->on_fail(sub { $event->error_reply("Something went wrong!"); })
      ->then(sub ($frob) {
          my $auth_uri = join q{?},
            "https://www.rememberthemilk.com/services/auth/",
            $self->rtm_client->_signed_content({ frob => $frob, perms => 'write' });

          my $text = "To authorize me to talk to RTM for you, follow this link: $auth_uri\n\n…and then tell me `milkauth complete`";
          $event->private_reply($text, { slack => $text });
        })
      ->retain;
  }

  # So we must have 'auth complete'
  my $frob_f = $self->frob_for($event->from_user);

  return $event->reply("You're not ready to complete auth yet!")
    unless $frob_f->is_ready;

  my $token_f = $frob_f
    ->then(sub ($frob) {
      $self->rtm_client->api_call('rtm.auth.getToken' => { frob => $frob })
    })
    ->then(sub ($rsp) {
      unless ($rsp->is_success) {
        return Future->fail(
          "Remember The Milk rejected our request to get a token!",
          cmilk_rsp => $rsp->_response,
        );
      }

      my $token = $rsp->get('auth')->{token};

      my $got = $self->set_user_preference($user, 'api-token', $token);

      $event->reply("You're authenticated!");
    })
    ->else(sub (@fail) {
      $Logger->log([ "get token: %s", \@fail ]);
    })->retain;
}

__PACKAGE__->add_preference(
  name      => 'api-token',
  validator => sub ($self, $value, @) {
    return (undef, "You can only set your API token with the milkauth command.")
      if defined $value;

    return (undef, undef);
  },
  describer => sub ($v) { return defined $v ? "<redacted>" : '<undef>' },
  default   => undef,
);

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

1;
