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
      }
    },
    tls_cert_file => "t/data/synergy.crt",
    tls_key_file => "t/data/synergy.key",
  }
);

$synergy->server->register_path('/ok', sub {
  return shift->new_response(200)->finalize;
});

my $http = Net::Async::HTTP->new(timeout => 2, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE);
$synergy->loop->add($http);
my $port = $synergy->server_port;

{
  my ($res) = $http->do_request(uri => "https://localhost:$port/ok")->get;
  ok($res->is_success, 'http server is responding');
}

done_testing;

