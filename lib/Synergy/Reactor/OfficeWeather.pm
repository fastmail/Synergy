use v5.36.0;
package Synergy::Reactor::OfficeWeather;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Data::GUID qw(guid_string);
use Future::AsyncAwait;
use JSON::MaybeXS;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';

my $API_ROOT = 'https://openapi.api.govee.com/router/api/v1';

# The building emoji we fall back to when a sensor has no emoji of its own.
my $DEFAULT_EMOJI = "\N{OFFICE BUILDING}";

my $JSON = JSON::MaybeXS->new->canonical;

has api_token => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

# A mapping of sensor (device) name to the emoji we should show for it.  Any
# sensor not named here gets the office building emoji instead.
has sensor_emoji => (
  isa     => 'HashRef',
  default => sub { {} },
  traits  => [ 'Hash' ],
  handles => { emoji_for_sensor => 'get' },
);

responder office_weather => {
  exclusive => 1,
  targeted  => 1,
  matcher     => sub ($, $text, @) { fc $text eq 'office weather' ? [] : () },
  help_titles => [ 'office weather' ],
  help        => "*office weather*: report the temperature in the office",
} => async sub ($self, $event) {
  $event->mark_handled;

  my @devices = await $self->_list_devices;

  # Fire off all the state lookups at once and let them run in parallel, then
  # keep each device paired with its own reading. -- claude, 2026-07-08
  my @state = map {; $self->_device_state($_) } @devices;
  await Future->needs_all(@state);

  my @readings;
  for my $i (0 .. $#devices) {
    my $reading = $state[$i]->get;

    # Only care about things that actually sense temperature or humidity.
    next unless defined $reading->{sensorTemperature}
             || defined $reading->{sensorHumidity};

    push @readings, [ $devices[$i], $reading ];
  }

  @readings = sort {
    ($a->[0]{deviceName}//'') cmp ($b->[0]{deviceName}//'')
  } @readings;

  unless (@readings) {
    return await $event->reply("I couldn't find any office thermometers to read.");
  }

  my @lines = map {; $self->_format_reading(@$_) } @readings;

  return await $event->reply(join "\n", "Office weather:", @lines);
};

# Hand back the decoded Govee response, dying with whatever the API told us if
# the call was not a success.  Govee is charmingly inconsistent: the list
# endpoint returns code/message, the state endpoint returns code/msg.  Accept
# either. -- claude, 2026-07-08
async sub _govee_request ($self, $method, $path, $body = undef) {
  my $res = await $self->hub->http_request(
    $method,
    "$API_ROOT$path",
    'Govee-API-Key' => $self->api_token,
    ($body ? (Content_Type => 'application/json', Content => $JSON->encode($body)) : ()),
  );

  my $json = decode_json($res->content);

  my $code = $json->{code};
  unless ($res->is_success && defined $code && $code == 200) {
    my $msg = $json->{message} // $json->{msg} // $res->status_line;
    $Logger->log([ "Govee API error (%s): %s", $code, $msg ]);
    die "Govee API error ($code): $msg\n";
  }

  return $json;
}

async sub _list_devices ($self) {
  my $json = await $self->_govee_request(GET => '/user/devices');
  return $json->{data}->@*;
}

async sub _device_state ($self, $device) {
  my $json = await $self->_govee_request(POST => '/device/state', {
    requestId => guid_string(),
    payload   => {
      sku    => $device->{sku},
      device => $device->{device},
    },
  });

  # Flatten the capability list into instance => value for easy lookup.
  my %reading;
  for my $cap ($json->{payload}{capabilities}->@*) {
    $reading{ $cap->{instance} } = $cap->{state}{value};
  }

  return \%reading;
}

sub _format_reading ($self, $device, $reading) {
  my $name  = $device->{deviceName} // $device->{device};
  my $emoji = $self->emoji_for_sensor($name) // $DEFAULT_EMOJI;

  my @bits;
  if (defined(my $f = $reading->{sensorTemperature})) {
    # Govee reports temperature in Fahrenheit.
    push @bits, sprintf '🌡 %.1f℉/%.1f℃', $f, ($f - 32) * 5 / 9;
  }
  push @bits, sprintf '💧 %.1f%%', $reading->{sensorHumidity}
    if defined $reading->{sensorHumidity};
  push @bits, 'OFFLINE' unless $reading->{online} // 1;

  return sprintf '%s *%s:* %s', $emoji, $name, join "\N{EM SPACE}", @bits;
}

1;
