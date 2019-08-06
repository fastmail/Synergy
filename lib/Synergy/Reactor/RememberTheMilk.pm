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
  );
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
