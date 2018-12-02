use v5.24.0;
package Synergy::Reactor::Weather;

use utf8;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use Synergy::Logger '$Logger';
use URI::Escape;
use JSON 2;

has api_token => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has locations => (
  is       => 'ro',
  isa      => 'ArrayRef',
  required => 1,
);

sub listener_specs {
  return {
    name      => 'weather',
    method    => 'handle_weather',
    exclusive => 1,
    predicate => sub ($self, $e) {
      $e->was_targeted && $e->text =~ /\Aweather\b/i;
    },
  };
}

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

sub handle_weather ($self, $event) {
  $event->mark_handled;

  return $event->reply(join "\n",
    "Current weather:",
    map {
      $self->format_weather($_)
    } $self->locations->@*,
  );
}

sub format_weather ($self, $location) {
  my $res = $self->hub->http_get(
    "https://api.openweathermap.org/data/2.5/weather?q=".uri_escape($location)."&APPID=".$self->api_token);
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
  my $wind_speed = ms_to_kmh($data->{wind}{speed});
  my $wind_dir = $bearing[$data->{wind}{deg} / 25.5];
  my $icon = $icons{$data->{weather}[0]{icon}}; # XXX day/night according to UTC time, adjust
  my $desc = $data->{weather}[0]{main};

  sprintf "%s %s: 🌡 %d℃/%d℉ 💧 %d%% 💨 %dkm/h %s %s %s",
    $place,
    $flag,
    $temp_c,
    $temp_f,
    $humidity,
    $wind_speed,
    $wind_dir,
    $icon,
    $desc,
  ;
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
