#!perl

use v5.24.0;
use warnings;

use lib 'lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Hub;

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
        todo      => [
          [ send => { text => "one" } ],
          [ send => { text => "two" } ],
          [ send => { text => "three" } ],
        ],
      }
    },
    reactors => {
      prometheus => { class => 'Synergy::Reactor::Prometheus' },
    },
  }
);

# Tests begin here.
testing_loop($synergy->loop);

wait_for {
  $synergy->channel_named('test-channel')->is_exhausted;
};

my $http = Net::Async::HTTP->new;
$synergy->loop->add($http);

my $port = $synergy->server_port;

my ($res) = $http->do_request(uri => "http://localhost:$port/metrics")->get;
is($res->content, <<EOF, 'metrics report three events receieved');
# HELP synergy_events_received_total Number of events received by reactors
# TYPE synergy_events_received_total counter
synergy_events_received_total{channel="test-channel",in="test",targeted="0",user="tester"} 3
EOF

done_testing;
