#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

if ($ENV{GITHUB_ACTION}) {
  plan skip_all => "test fails under GitHub Actions at present";
}

use Synergy::Logger::Test '$Logger';

use IO::Async::Loop;
use IO::Async::Test;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;
use Plack::Response;
use Synergy::Tester;

my $synergy = Synergy::Tester->new_tester({
  tls_cert_file => "t/data/synergy.crt",
  tls_key_file  => "t/data/synergy.key",
});

$synergy->server->register_path(
  '/ok',
  sub { return Plack::Response->new(200)->finalize; },
  'test file',
);

my $http = Net::Async::HTTP->new(
  timeout => 2,
  SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE
);

$synergy->loop->add($http);
my $port = $synergy->server_port;

{
  # Doing this test first, before the successful HTTPS test.
  # Net::Async::HTTP caches connections by host:port, ignoring scheme
  # So successful HTTPS connection is reused for the HTTP test, which then
  # succeeds
  # I consider this to be a Net::Async::HTTP bug
  my $f = $http->do_request(uri => "http://localhost:$port/ok");
  ok($f->failure, 'http request to https server failed');
}

{
  my ($res) = $http->do_request(uri => "https://localhost:$port/ok")->get;
  ok($res->is_success, 'https server is responding');
}

done_testing;
