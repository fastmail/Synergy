#!perl

use v5.34.0;
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

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
      }
    },
    tls_cert_file => "t/data/synergy.crt",
    tls_key_file => "t/data/synergy.key",
    server_port => empty_port(),
  }
);

$synergy->server->register_path(
  '/ok',
  sub { return Plack::Response->new(200)->finalize; },
  'test file',
);

my $http = Net::Async::HTTP->new(timeout => 2, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE);
$synergy->loop->add($http);
my $port = $synergy->server_port;

{
  # Doing this test first, before the successful HTTPS test.
  # Net::Async::HTTP caches connections by host:port, ignoring scheme
  # So successful HTTPS connection is reused for the HTTP test, which then succeeds
  # I consider this to be a Net::Async::HTTP bug
  my $f = $http->do_request(uri => "http://localhost:$port/ok");
  ok($f->failure, 'http request to https server failed');
}

{
  my ($res) = $http->do_request(uri => "https://localhost:$port/ok")->get;
  ok($res->is_success, 'https server is responding');
}


done_testing;

