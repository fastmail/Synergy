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
use JSON::MaybeXS qw(decode_json encode_json);
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

sub listener_specs {
  return (
    {
      name      => 'oncall',
      method    => 'handle_oncall',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^pd oncall\s*$/i },
      help_entries => [
        { title => 'oncall', text => '*oncall*: show a list of who is on call in PagerDuty right now' },
      ],
    },
  );
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
    'Authorization' => "Token token=" . $self->api_key,
    Accept         => 'application/vnd.pagerduty+json;version=2"',
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

sub handle_oncall ($self, $event) {
  $event->mark_handled;

  $self->_pd_request(GET => '/oncalls')
    ->then(sub ($data) {
      my @oncall = map {; $_->{user} }
                   grep {; $_->{escalation_level} == 1}
                   $data->{oncalls}->@*;

      unless (@oncall) {
        $event->reply("Nobody seems to be oncall right now...weird!");
        return;
      }

      my @names = map {; $_->{summary} } @oncall;

      $event->reply("current oncall: " . join q{, }, @names);
    })
    ->else(sub (@err) {
      $event->reply("Something went wrong talking to PagerDuty, sorry.");
      return;
    })
    ->retain;

}

__PACKAGE__->meta->make_immutable;

1;
