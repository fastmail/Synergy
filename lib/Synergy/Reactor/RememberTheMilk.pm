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
      predicate => sub ($self, $e) { $e->was_targeted && $e->text eq 'milk' },
    },
  );
}

sub handle_milk ($self, $event) {
  $event->mark_handled;

  return $event->error_reply("I don't have an RTM auth token for you.")
    unless $self->user_has_preference($event->from_user, 'api-token');

  my $rsp_f = $self->rtm_client->api_call('rtm.tasks.getList' => {
    auth_token => $self->get_user_preference($event->from_user, 'api-token'),
    filter     => 'status:incomplete',
  });

  $rsp_f->then(sub ($rsp) {
    $event->reply("I got a result and it was "
      . ($rsp->is_success ? "successful" : "no good")
      . ".");
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
