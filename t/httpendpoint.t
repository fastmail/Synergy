#!perl

use v5.32.0;
use warnings;

use lib 'lib', 't/lib';

use Test::More;

use Synergy::Logger::Test '$Logger';

use Net::Async::HTTP;
use Plack::Response;
use MIME::Base64 'encode_base64';
use Synergy::Tester;

package Synergy::Channel::Test::HTTPEndpoint {

  use Moose;
  extends 'Synergy::Channel::Test';
  with 'Synergy::Role::HTTPEndpoint';

  has '+http_path' => (
    default => '/test',
  );

  sub http_app {
    return Plack::Response->new(200)->finalize;
  }
}

my $result = Synergy::Tester->testergize({
  extra_channels => {
    'test-channel-endpoint' => {
      class => 'Synergy::Channel::Test::HTTPEndpoint',
    },
    'test-channel-endpoint-auth' => {
      class => 'Synergy::Channel::Test::HTTPEndpoint',
      http_path => '/auth',
      http_username => 'someuser',
      http_password => 'somepass',
    },
  },
});

my $http = Net::Async::HTTP->new(timeout => 2);
$result->synergy->loop->add($http);
my $port = $result->synergy->server_port;

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/test")->get;
  ok($res->is_success, 'http server is responding');
}

{
  my ($res) = $http->do_request(uri => "http://localhost:$port/auth")->get;
  is($res->code, 401, 'http request to auth endpoint returns 401');
}

{
  my ($res) = $http->do_request(
    uri => "http://localhost:$port/auth",
    headers => {
      'Authorization' => "Basic ".MIME::Base64::encode_base64("someuser:somepass", "")
    }
  )->get;
  ok($res->is_success, 'http request to auth endpoint with good creds succeeds');
}

{
  my ($res) = $http->do_request(
    uri => "http://localhost:$port/auth",
    headers => {
      'Authorization' => "Basic ".MIME::Base64::encode_base64("someuser:badpass", "")
    }
  )->get;
  is($res->code, 401, 'http request to auth endpoint with wrong creds returns 401');
}

done_testing;
