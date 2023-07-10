#!perl

use v5.32.0;
use warnings;

use lib 'lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::EmptyPort qw(empty_port);
use Synergy::Hub;

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    server_port => empty_port(),
    metrics_path => '/metrics',
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
my $expect = <<'END';
# HELP synergy_events_received_total Number of events received by Synergy
# TYPE synergy_events_received_total counter
synergy_events_received_total{channel="test-channel",in="test",targeted="0",user="tester"} 3
END

isnt(
  index($res->content, $expect), -1,
  'metrics report three events receieved'
) or diag "Have: " . $res->content;

done_testing;
