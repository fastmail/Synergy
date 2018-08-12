use v5.24.0;
package Synergy::HTTPServer;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

use Net::Async::HTTP::Server::PSGI;
use Plack::App::URLMap;
use Plack::Request;
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

has http_server => (
  is => 'ro',
  isa => 'Net::Async::HTTP::Server::PSGI',
  init_arg => undef,
  lazy => 1,
  default => sub ($self) {
    my $server = Net::Async::HTTP::Server::PSGI->new(
      app => sub ($env) {
        $env->{PATH_INFO} = '/' unless $env->{PATH_INFO};
        my $req = Plack::Request->new($env);

        unless ($self->path_is_registered($req->path_info)) {
          $Logger->log([
            "could not find app for %s, ignoring",
            $req->path_info,
          ]);
          return $req->new_response(404)->finalize;
        }

        return $self->app_for_path($req->path_info)->($req);
      },
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
  $self->http_server->listen(
    addr => {
      family => "inet",
      socktype => "stream",
      port => $self->server_port,
    },
    on_listen_error => sub { die "Cannot listen - $_[-1]\n" },
  );

}

1;
