use v5.24.0;
use warnings;
package Synergy::Reactor::VicEPA;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use List::Util qw(first uniq);
use Synergy::Util qw(parse_date_for_user);

has api_key => (
  is => 'ro',
  required => 1,
);

has site_id => (
  is => 'ro',
  required => 1,
);

sub listener_specs {
  return {
    name      => 'airwatch',
    method    => 'handle_airwatch',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->was_targeted;
      return unless $e->text =~ /\Aairwatch\z/i;
    },
  };
}

sub handle_airwatch ($self, $event) {
  $event->mark_handled;

  my $now = DateTime->now(time_zone => 'UTC');
  my $ago = $now->clone->subtract(hours => 12);

  my $url = sprintf 'https://gateway.api.epa.vic.gov.au/environmentMonitoring/v1/sites/%s/parameters?since=%s&until=%s',
    $self->site_id,
    $ago->strftime('%FT%TZ'),
    $now->strftime('%FT%TZ');

  my $http_future = $self->hub->http_client->GET(
    $url,
    headers => [
      'X-API-Key' => $self->api_key,
    ],
  );

  $http_future
    ->then(sub ($res) {
      my $report  = JSON::MaybeXS->new->decode($res->decoded_content);
      my $where   = $report->{siteName};
      my @by_time = sort { $a->{since} cmp $b->{since} }
                    $report->{siteHealthAdvices}->@*;
      my @by_val  = sort { $a->{value} <=> $b->{value} }
                    $report->{siteHealthAdvices}->@*;

      unless (@by_time) {
        $event->reply("I couldn't get any measurements in $where for the last 12 hours!");
        return Future->done;
      }

      if ($by_val[0]{healthAdvice} eq $by_val[-1]{healthAdvice}) {
        $event->reply("Air quality in $where for the past 12h: $by_val[0]{healthAdvice}");
        return Future->done;
      }

      $event->reply(
        sprintf "Air quality in $where for the past 12h: ranged from %s to %s; currently %s",
          $by_val[0]{healthAdvice},
          $by_val[-1]{healthAdvice},
          $by_time[-1]{healthAdvice},
      );
      return Future->done;
    })
    ->else(sub (@err) { $event->error_reply("Air quality check failed."); })
    ->retain;
}

1;
