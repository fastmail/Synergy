use v5.24.0;
use warnings;
package Synergy::HTTPServer;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

use Net::Async::HTTP::Server::PSGI;
use IO::Async::SSL;
use Plack::App::URLMap;
use Plack::Middleware::AccessLog;
use Plack::Response;
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
    _register_path    => 'set',
    registered_paths  => 'keys',
    _registrations    => 'kv',
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

has http_server => (
  is => 'ro',
  isa => 'Net::Async::HTTP::Server::PSGI',
  init_arg => undef,
  lazy => 1,
  default   => sub ($self) {
    my $server = Net::Async::HTTP::Server::PSGI->new(
      app => Plack::Middleware::AccessLog->new(
        logger => sub ($msg) {
          chomp($msg);
          $Logger->log("HTTPServer: access: $msg");
        }
      )->wrap(
        $self->_urlmap->to_app
      )
    );
  },
);

has _urlmap => (
  is => 'ro',
  lazy => 1,
  init_arg  => undef,
  default   => sub {
    Plack::App::URLMap->new;
  },
);

# $app is a PSGI app
sub register_path ($self, $path, $app, $by) {
  confess "bogus HTTP path" unless $path && $path =~ m{\A(/[-_0-9a-z]+)+\z}i;

  my $path_slash = "$path/";
  my @known = map {; "$_/" } $self->registered_paths;

  my ($is_prefix_of) = grep {; index($_, $path_slash) == 0 } @known;
  confess "refusing to register $path because it is a prefix of $is_prefix_of"
    if $is_prefix_of;

  my ($is_suffix_of) = grep {; index($path_slash, $_) == 0 } @known;
  confess "refusing to register $path because it is a suffix of $is_suffix_of"
    if $is_suffix_of;

  $self->_register_path($path, $by);

  $self->_urlmap->map($path => $app);

  # We need to re-prepare the app every time we map a new path, because it
  # rebuilds state used in routing.  Why doesn't URLMap do this implicitly?  I
  # couldn't say, but I'm guessing "faster startup". -- rjbs, 2021-12-31
  $self->_urlmap->prepare_app;

  $Logger->log("HTTP path $path registered" . (length $by ? " by $by" : q{}));
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
