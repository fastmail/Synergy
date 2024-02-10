#!perl
use v5.32.0;
use warnings;

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Net::EmptyPort qw(empty_port);
use Synergy::Tester;

my $result = Synergy::Tester->testergize(
  {
    server_port => empty_port(),
    todo      => [
      [ send => { text => "one" } ],
      [ send => { text => "two" } ],
      [ send => { text => "three" } ],
    ],
    reactors => {
      prometheus => { class => 'Synergy::Reactor::Prometheus' },
    },
  }
);

my $http = Net::Async::HTTP->new;
$result->synergy->loop->add($http);

my $port = $result->synergy->server_port;

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
