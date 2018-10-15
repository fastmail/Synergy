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
use MIME::Base64 'encode_base64';

# Initialize Synergy.
my $synergy = Synergy::Hub->synergize(
  {
    user_directory => "t/data/users.yaml",
    channels => {
      'test-channel' => {
        class     => 'Synergy::Channel::Test',
      }
    },
    http_auth => {
      '/auth' => {
        username => 'admin',
        password => 'secret'
      },
    }
  }
);

$synergy->server->register_path('/ok', sub {
  return shift->new_response(200)->finalize;;
});
$synergy->server->register_path('/auth', sub {
  return shift->new_response(200)->finalize;;
});
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

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/auth")->get;
  is($res->code, 401, 'http request to auth endpoint returns 401');
}

{
  my ($res) = $http->do_request(
    uri => "http://localhost:$port/auth",
    headers => {
      'Authorization' => "Basic ".MIME::Base64::encode_base64("admin:secret", "")
    }
  )->get;
  ok($res->is_success, 'http request to auth endpoint with good creds succeeds');
}

{
  my ($res) = $http->do_request(
    uri => "http://localhost:$port/auth",
    headers => {
      'Authorization' => "Basic ".MIME::Base64::encode_base64("admin:badpass", "")
    }
  )->get;
  is($res->code, 401, 'http request to auth endpoint with wrong creds returns 401');
}

done_testing;

