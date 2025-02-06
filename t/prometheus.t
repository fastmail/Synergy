#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Synergy::Tester;
use Synergy::Test::EmptyPort qw(empty_port);
use Synergy::Hub;

my $synergy = Synergy::Tester->new_tester({
  server_port => empty_port(),
  reactors => {
    prometheus => { class => 'Synergy::Reactor::Prometheus' },
  },
});

my $result = $synergy->run_test_program([
  [ send => { text => "one" } ],
  [ send => { text => "two" } ],
  [ send => { text => "three" } ],
]);

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
