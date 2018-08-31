use v5.24.0;
package Synergy::HTTPServer;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

use Net::Async::HTTP::Server::PSGI;
use IO::Async::SSL;
use Plack::App::URLMap;
use Plack::Middleware::AccessLog;
use Plack::Request;
use Plack::Middleware::Auth::Basic;
use Carp;
use Try::Tiny;

use Synergy::Logger '$Logger';

with 'Synergy::Role::HubComponent';

has _registered_paths => (
  is      => 'ro',
  isa     => 'HashRef',
  traits  => [ 'Hash' ],
  default => sub { {} },
  handles => {
    register_pathname  => 'set',
    path_is_registered => 'exists',
    app_for_path       => 'get',
  },
);

has server_port => (
  is => 'ro',
  isa => 'Int',
  required => 1,
);

has tls_cert_file => (
  is => 'ro',
  isa => 'Str',
);

has tls_key_file => (
  is => 'ro',
  isa => 'Str',
);

has http_auth => (
  isa     => 'HashRef',
  traits  => [ 'Hash' ],
  default => sub { {} },
  handles => {
    path_requires_auth        => 'exists',
    auth_credentials_for_path => 'get',
  },
);

has http_server => (
  is => 'ro',
  isa => 'Net::Async::HTTP::Server::PSGI',
  init_arg => undef,
  lazy => 1,
  default => sub ($self) {
    my $server = Net::Async::HTTP::Server::PSGI->new(
      app => Plack::Middleware::AccessLog->new(
        logger => sub ($msg) {
          chomp($msg);
          $Logger->log("HTTPServer: access: $msg");
        }
      )->wrap(sub ($env) {
        $env->{PATH_INFO} = '/' unless $env->{PATH_INFO};
        my $req = Plack::Request->new($env);

        unless ($self->path_is_registered($req->path_info)) {
          $Logger->log([
            "could not find app for %s, ignoring",
            $req->path_info,
          ]);
          return $req->new_response(404)->finalize;
        }

        my $app = $self->app_for_path($req->path_info);

        if ($self->path_requires_auth($req->path_info)) {
          my $creds = $self->auth_credentials_for_path($req->path_info);
          my ($authuser, $authpass) = $creds->@*;

          return Plack::Middleware::Auth::Basic->new(
            authenticator => sub ($user, $pass, $env) {
              return $user eq $authuser && $pass eq $authpass;
            }
          )->wrap(
            # can't wrap $app as-is because it takes a req, not an env
            sub ($env) {
              my $req = Plack::Request->new($env);
              return $app->($req);
            }
          )->($env);
        }

        return $app->($req);
      }),
    );
  },
);

# $app is a PSGI app
sub register_path ($self, $path, $app) {
  confess "$path is already registered with HTTP server!"
    if $self->path_is_registered($path);

  confess "refusing to register $path"
    unless $path =~ m{^/} && (1 == ($path =~ m{/}g));

  $self->register_pathname($path, $app);
  $Logger->log("registered $path");
}

sub start ($self) {
  $self->loop->add($self->http_server);

  $Logger->log([ "listening on port %s", $self->server_port ]);

  my %opts = (
    addr => {
      family => "inet",
      socktype => "stream",
      port => $self->server_port,
    },
    on_listen_error => sub { die "Cannot listen - $_[-1]\n" },
  );

  if ($self->tls_cert_file && $self->tls_key_file) {
    $self->loop->SSL_listen(listener => $self->http_server,
      %opts,
      SSL_cert_file => $self->tls_cert_file,
      SSL_key_file  => $self->tls_key_file,
      on_ssl_error    => sub {
        # do we even care about this?
        $Logger->log("HTTPServer: SSL error - $_[-1]");
      },
    );
  }
  else {
    $self->http_server->listen(%opts);
  }
}

1;
