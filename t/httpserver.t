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
use Plack::Response;
use Synergy::Hub;

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
      }
    },
  }
);

$synergy->server->register_path(
  '/ok',
  sub { return Plack::Response->new(200)->finalize; },
  'test file',
);

# Tests begin here.
testing_loop($synergy->loop);

my $http = Net::Async::HTTP->new(timeout => 2);
$synergy->loop->add($http);
my $port = $synergy->server_port;

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/ok")->get;
  ok($res->is_success, 'http server is responding');
}

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/nonexistent")->get;
  is($res->code, 404, 'nonexistent http path returns 404');
}

done_testing;

