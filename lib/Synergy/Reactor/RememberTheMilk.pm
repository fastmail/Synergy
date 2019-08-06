use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::RememberTheMilk;

use Moose;
with 'Synergy::Role::Reactor',
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
  return unless $self->user_has_preference($user, 'api-token');

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
    auth_token => $self->get_user_preference($user, 'api-token'),
  });

  return $store->{$username} = $rsp_f->then(sub ($rsp) {
    unless ($rsp->is_success) {
      $Logger->log([ "failed to create a timeline: %s", $rsp->_response ]);
      return Future->fail("couldn't get timeline");
    }

    return Future->done($rsp->get('timeline'));
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
  );
}

sub handle_todo ($self, $event) {
  $event->mark_handled;

  my (undef, $todo) = split /\s+/, $event->text, 2;

  return $event->error_reply("I don't have an RTM auth token for you.")
    unless $self->user_has_preference($event->from_user, 'api-token');

  return $event->error_reply("You didn't tell me what you want to do!")
    unless length $todo;

  my $tl_f = $self->timeline_for($event->from_user);

  $tl_f->then(sub ($tl) {
    my $rsp_f = $self->rtm_client->api_call('rtm.tasks.add' => {
      auth_token => $self->get_user_preference($event->from_user, 'api-token'),
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

      # {{{"list": {"id": "7087408", "taskseries": [{"created": "2019-08-06T20:56:13Z", "id": "389696269", "location_id": "", "modified": "2019-08-06T20:56:13Z", "name": "run Jerrica under daemontools", "notes": [], "participants": [], "source": "api:fd58375d2e592a7f1e90ff575eae6e7c", "tags": [], "task": [{"added": "2019-08-06T20:56:13Z", "completed": "", "deleted": "", "due": "2019-08-09T04:00:00Z", "estimate": "", "has_due_time": "0", "id": "679750283", "postponed": "0", "priority": "N"}], "url": ""}]}, "stat": "ok", "transaction": {"id": "3515949782", "undoable": "0"}}}}
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
    unless $self->user_has_preference($event->from_user, 'api-token');

  my $rsp_f = $self->rtm_client->api_call('rtm.tasks.getList' => {
    auth_token => $self->get_user_preference($event->from_user, 'api-token'),
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
      "*Tasks found:*\n",
      map {; $_->{string} } @lines
    );
  })->retain;
}

__PACKAGE__->add_preference(
  name      => 'api-token',
  validator => sub ($self, $value, @) {
    return $value if $value =~ /\A[a-f0-9]+\z/;
    return (undef, "Your user-id must be a hex string.")
  },
  describer => sub ($v) { return defined $v ? "<redacted>" : '<undef>' },
  default   => undef,
);

1;
