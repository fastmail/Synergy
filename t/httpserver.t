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
use Plack::Response;
use Synergy::Hub;

my $port = empty_port();

note "will use port $port for test HTTP server";

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    server_port => $port,
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

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/ok")->get;
  ok($res->is_success, 'http server is responding');
}

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/nonexistent")->get;
  is($res->code, 404, 'nonexistent http path returns 404');
}

done_testing;

