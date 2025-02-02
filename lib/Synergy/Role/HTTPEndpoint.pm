use v5.36.0;
package Synergy::Role::HTTPEndpoint;

use Moose::Role;
use namespace::clean;

use Plack::Middleware::Auth::Basic;
use Plack::Request;

requires 'http_app';

has http_path => (
  is    => 'ro',
  isa   => 'Str',
  lazy  => 1,
  default => sub { confess "http path did not have an effective default" }
);

has http_username => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_http_username',
);

has http_password => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_http_password',
);

has _app => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $app = sub { $self->http_app(shift) };

    if ($self->has_http_username && $self->has_http_password) {
      $app = Plack::Middleware::Auth::Basic->new(
        authenticator => sub ($username, $password, $env) {
          return $username eq $self->http_username && $password eq $self->http_password;
        }
      )->wrap($app);
    }

    return $app;
  },
);

sub BUILD ($self, @) {
  confess "http_username and http_password must be supplied together"
    if $self->has_http_username ^ $self->has_http_password;
}

after start => sub ($self) {
  $self->hub->server->register_path($self->http_path, $self->_app, $self->name);
};

no Moose::Role;
1;
