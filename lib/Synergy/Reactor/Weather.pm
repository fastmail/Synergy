use v5.32.0;
package Synergy::Reactor::Weather;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use JSON::MaybeXS;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use URI::Escape;

has api_token => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has locations => (
  isa      => 'ArrayRef',
  required => 1,
  traits   => [ 'Array' ],
  handles  => { locations => 'elements' },
);

# https://openweathermap.org/weather-conditions
my %icons = (
  '01d' => '☀️:', # clear sky
  '02d' => '🌤', # few clouds
  '03d' => '☁️:', # scattered clouds
  '04d' => '🌥', # broken clouds
  '09d' => '🌦', # shower rain
  '10d' => '🌧', # rain
  '11d' => '⛈:', # thunderstorm
  '13d' => '🌨', # snow
  '50d' => '🌫', # mist

  '01n' => '🌕', # clear sky
  '02n' => '',   # few clouds
  '03n' => '☁️',  # scattered clouds
  '04n' => '',   # broken clouds
  '09n' => '',   # shower rain
  '10n' => '🌧', # rain
  '11n' => '⛈:', # thunderstorm
  '13n' => '🌨', # snow
  '50n' => '🌫', # mist
);

my @bearing = qw(
  N NNE NE ENE
  E ESE SE SSE
  S SSW SW WSW
  W WNW NW NNW
);

command weather => {
  help => "*weather*: what's the weather like in all the places?",
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->error_reply("It's just *weather*, with no arguments.");
  }

  my @reports = map {; $self->lookup_weather($_) } $self->locations;

  await Future->needs_all(@reports);

  return await $event->reply(join "\n",
    "Current weather:",
    map { $_->get } @reports
  );
};

async sub lookup_weather ($self, $location) {
  my $res = await $self->hub->http_get(
    "https://api.openweathermap.org/data/2.5/weather?q=".uri_escape($location)."&APPID=".$self->api_token
  );

  unless ($res->is_success) {
    $Logger->log([ "error fetching weather for $location: %s", $res->as_string ]);
    return;
  }

  my $data = decode_json($res->content);

  # Melbourne 🇦🇺: 🌡 15℃/47℉ 💧 67% 💨 26km/h WSW 🌧 Rain

  my $place = $data->{name};
  my $flag = country_to_flag($data->{sys}{country});
  my $temp_c = kelvin_to_celsius($data->{main}{temp});
  my $temp_f = kelvin_to_fahrenheit($data->{main}{temp});
  my $humidity = $data->{main}{humidity};
  my $wind_speed_kph = ms_to_kmh($data->{wind}{speed});
  my $wind_speed_mph = $wind_speed_kph * 0.62;
  my $wind_dir = $bearing[$data->{wind}{deg} / 25.5];
  my $icon = $icons{$data->{weather}[0]{icon}}; # XXX day/night according to UTC time, adjust
  my $desc = $data->{weather}[0]{main};

  return join("\N{EM SPACE}",
    sprintf("*%s %s:*", $flag, $place),
    sprintf("🌡 %d℃/%d℉", $temp_c, $temp_f),
    sprintf("💧 %d%%", $humidity),
    sprintf("💨 %dkph/%dmph %s", $wind_speed_kph, $wind_speed_mph, $wind_dir),
    sprintf("%s %s", $icon, $desc),
  );
}

sub kelvin_to_celsius ($k) {
  return $k - 273;
}

sub kelvin_to_fahrenheit ($k) {
  return (9/5) * ($k - 273) + 32;
}

sub ms_to_kmh ($ms) {
  return $ms * 3.6;
}

sub country_to_flag ($cc) {
  return join('', map { pack 'U', 0x1f1e6+ord(lc($_))-0x61 } split(//, $cc) );
}

1;
