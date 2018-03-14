use v5.24.0;
package Synergy::Hub;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

use Try::Tiny;

has user_directory => (
  is  => 'ro',
  isa => 'Object',
  required  => 1,
);

for my $pair (
  [ qw( channel channels ) ],
  [ qw( reactor reactors ) ],
) {
  my ($s, $p) = @$pair;

  my $exists = "_$s\_exists";
  my $add    = "_add_$s";

  has "$s\_registry" => (
    isa => 'HashRef[Object]',
    init_arg  => undef,
    default   => sub {  {}  },
    traits    => [ 'Hash' ],
    handles   => {
      "$s\_named" => 'get',
      $p          => 'values',
      $add        => 'set',
      $exists     => 'exists',
    },
  );

  Sub::Install::install_sub({
    as    => "register_$s",
    code  => sub ($self, $thing) {
      my $name = $thing->name;

      confess("$s named $name is already registered") if $self->$exists($name);

      $self->$add($name, $thing);
      $thing->register_with_hub($self);
      return;
    }
  });
}

sub handle_event ($self, $event, $rch) {
  my @hits;
  for my $reactor ($self->reactors) {
    for my $listener ($reactor->listeners) {
      next unless $listener->matches_event($event);
      push @hits, [ $reactor, $listener ];
    }
  }

  # Probably we later want a "huh?" for targeted/private events.
  return unless @hits;

  if (1 < grep {; $_->[1]->is_exclusive } @hits) {
    $rch->reply("Sorry, I find that message ambiguous.");
    return;
  }

  for my $hit (@hits) {
    my $reactor = $hit->[0];
    my $method  = $hit->[1]->method;

    try {
      $reactor->$method($event, $rch);
    } catch {
      my $error = $_;

      $error =~ s/\n.*//ms;

      $rch->reply("My reactor ($reactor) crashed while handling your message.  ($error). Sorry!");
    };
  }

  return;
}

has loop => (
  reader => '_get_loop',
  writer => '_set_loop',
  init_arg  => undef,
);

sub loop ($self) {
  my $loop = $self->_get_loop;
  confess "tried to get loop, but no loop registered" unless $loop;
  return $loop;
}

sub set_loop ($self, $loop) {
  confess "tried to set loop, but look already set" if $self->_get_loop;
  $self->_set_loop($loop);

  $_->start for $self->channels;
  $_->start for $self->reactors;

  return $loop;
}

has http => (
  is => 'ro',
  isa => 'Net::Async::HTTP',
  lazy => 1,
  default => sub ($self) {
    my $http = Net::Async::HTTP->new(
      max_connections_per_host => 5, # seems good?
    );

    $self->loop->add($http);

    return $http;
  },
);

sub http_get {
  return shift->http_request('GET' => @_);
}

sub http_request ($self, $method, $url, %args) {
  my $content = delete $args{Content};
  my $content_type = delete $args{Content_Type};

  my @args = $url;

  if ($method ne 'GET' && $method ne 'HEAD') {
    push @args, $content // [];
  }

  if ($content_type) {
    push @args, content_type => $content_type;
  }

  push @args, headers => \%args;

  # The returned future will run the loop for us until we return. This makes
  # it asynchronous as far as the rest of the code is concerned, but
  # sychronous as far as the caller is concerned.
  return $self->http->$method(
    @args
  )->on_fail( sub {
    my $failure = shift;
    warn "Failed to $method $url: $failure\n";
  } )->get;
}

1;
