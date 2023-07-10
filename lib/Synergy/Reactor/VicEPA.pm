use v5.32.0;
use warnings;
package Synergy::Reactor::VicEPA;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use utf8;
use experimental qw(lexical_subs signatures);
use namespace::clean;

use Future::AsyncAwait;
use List::Util qw(uniq);
use Synergy::CommandPost;
use Synergy::Util qw(parse_date_for_user);
use Try::Tiny;

use Synergy::Logger '$Logger';

has api_key => (
  is => 'ro',
  required => 1,
);

has site_id => (
  is => 'ro',
  required => 1,
);

has latitude => (
  is => 'ro',
  required => 1,
);

has longitude => (
  is => 'ro',
  required => 1,
);

has forecast_region_name => (
  is => 'ro',
  required => 1,
);

command airwatch => {
  help => "*airwatch*: report on recent air quality",
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->error_reply("*airwatch* doesn't take any arguments.");
  }

  my $now = DateTime->now(time_zone => 'UTC');
  my $ago = $now->clone->subtract(hours => 12);

  my $seen = $self->hub->http_client->GET(
    sprintf(
      'https://gateway.api.epa.vic.gov.au/environmentMonitoring/v1/sites/%s/parameters?since=%s&until=%s',
      $self->site_id,
      $ago->strftime('%FT%TZ'),
      $now->strftime('%FT%TZ'),
    ),
    headers => [
      'X-API-Key' => $self->api_key,
    ],
  );

  my $forecast = $self->hub->http_client->GET(
    sprintf(
      'https://gateway.api.epa.vic.gov.au/environmentMonitoring/v1/forecasts/?environmentalSegment=%s&location=%s,%s',
      'air',
      $self->latitude,
      $self->longitude,
    ),
    headers => [
      'X-API-Key' => $self->api_key,
    ],
  );

  my $ok = eval { await Future->needs_all($seen, $forecast); 1; };
  unless ($ok) {
    my $error = $@;
    $Logger->log([ "Air quality check failed: %s", $error ]);
    return await $event->error_reply("Air quality check failed.");
  }

  my $report  = JSON::MaybeXS->new->decode($seen->get->decoded_content);
  my $where   = $report->{siteName};
  my @by_time = sort { $a->{since} cmp $b->{since} }
                $report->{siteHealthAdvices}->@*;
  my @by_val  = sort { $a->{averageValue} <=> $b->{averageValue} }
                $report->{siteHealthAdvices}->@*;

  my $report_str = "I couldn't get any measurements in $where for the last 12 hours!";

  if (@by_time) {
    if ($by_val[0]{healthAdvice} eq $by_val[-1]{healthAdvice}) {
      $report_str = "Air quality in $where for the past 12h: $by_val[0]{healthAdvice}";
    } else {
      $report_str = sprintf "Air quality in $where for the past 12h: ranged from %s to %s; currently %s.",
        $by_val[0]{healthAdvice},
        $by_val[-1]{healthAdvice},
        $by_time[-1]{healthAdvice};
    }
  }

  my $fcast   = JSON::MaybeXS->new->decode($forecast->get->decoded_content);

  # Melbourne comes back as " Melbourne"
  for ($fcast->{records}->@*) {
    $_->{regionName} =~ s/^\s+//;
    $_->{regionName} =~ s/\s+$//;
  }

  my @records =
    sort {;
          $a->{regionName} cmp $b->{regionName}
      ||  $a->{since}      cmp $b->{since}
    }
    grep {;
      $_->{regionName} eq $self->forecast_region_name
    }
    $fcast->{records}->@*;

  my $fcast_str = "I couldn't get a forecast for $where.";

  if (@records) {
    $fcast_str = q{The forecast is:};
    my %saw_region;
    for my $record (@records) {
      next if $saw_region{ $record->{regionName} }++;

      my $since = DateTime::Format::ISO8601->parse_datetime($record->{since})
                                           ->set_time_zone('Australia/Melbourne');
      my $until = DateTime::Format::ISO8601->parse_datetime($record->{until})
                                           ->set_time_zone('Australia/Melbourne');

      my $AU = q{🇦🇺};
      $fcast_str .= sprintf "\n%s, %s to %s $AU: %s",
        $record->{regionName},
        $self->hub->format_friendly_date(
          $since,
          {
            include_time_zone => 0,
            maybe_omit_day    => 1,
          },
        ),
        $self->hub->format_friendly_date(
          $until,
          {
            include_time_zone => 0,
            maybe_omit_day    => 1,
          },
        ),
        $record->{title};
    }
  }

  await $event->reply("$report_str\n$fcast_str");
};

1;
