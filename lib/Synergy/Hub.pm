use v5.28.0;
use warnings;
package Synergy::Hub;
# ABSTRACT: synergy's brain

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

with (
  'Synergy::Role::ManagesState',
);

use Synergy::Logger '$Logger';

use DBI;
use IO::Async::Timer::Periodic;
use Module::Runtime qw(require_module);
use Net::Async::HTTP;
use Synergy::UserDirectory;
use Path::Tiny ();
use Plack::App::URLMap;
use Prometheus::Tiny 0.002;
use Synergy::Environment;
use Synergy::HTTPServer;
use Synergy::Util qw(read_config_file);
use Try::Tiny;
use URI;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Defined::KV;

sub env;
has env => (
  is => 'ro',
  isa => 'Synergy::Environment',
  handles => [qw(
    name
    server_port
    format_friendly_date
    user_directory
  )],
);

has server => (
  is => 'ro',
  isa => 'Synergy::HTTPServer',
  lazy => 1,
  default => sub ($self) {
    my $s = Synergy::HTTPServer->new({
      name          => '_http_server',
      server_port   => $self->env->server_port,
      tls_cert_file => $self->env->tls_cert_file,
      tls_key_file  => $self->env->tls_key_file,
    });

    $s->register_with_hub($self);
    return $s;
  },
);

has prom => (
  is => 'ro',
  lazy => 1,
  default => sub { Prometheus::Tiny->new },
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

      for my $what (qw(channel reactor)) {
        my $what_exists = "_$what\_exists";
        if ($self->$what_exists($name)) {
          confess("$what named '$name' exists: cannot register $s named that");
        }
      }

      $self->$add($name, $thing);
      $thing->register_with_hub($self);
      return;
    }
  });
}

# Get a channel or reactor named this
sub component_named ($self, $name) {
  return $self->user_directory if lc $name eq 'user';
  return $self->reactor_named($name) if $self->_reactor_exists($name);
  return $self->channel_named($name) if $self->_channel_exists($name);
  confess("Could not find channel or reactor named '$name'");
}

sub handle_event ($self, $event) {
  $Logger->log([
    "%s event from %s/%s: %s",
    $event->type,
    $event->from_channel->name,
    $event->from_user ? 'u:' . $event->from_user->username : $event->from_address,
    $event->text,
  ]);

  my @hits = map {; $_->potential_reactions_to($event) } $self->reactors;

  if (1 < grep {; $_->is_exclusive } @hits) {
    my @names = sort map {; join q{},
      $_->description,
      $_->is_exclusive ? (' (exclusive)') : (),
    } @hits;
    $event->error_reply("Sorry, I find that message ambiguous.\n" .
                    "The following reactors matched: " . join(", ", @names));

    return;
  }

  for my $hit (@hits) {
    my $reactor = $hit->reactor;
    my $rname   = $reactor->name;

    try {
      # We should always return a future -- specifically, a single future that
      # represents all pending (or complete) action as the result of this
      # method.  Sometimes, though, we don't, largely for historical reasons.
      # Rather than force ourselves to fix them all up front, let's just ignore
      # false-returning reactions.  Things that return true, non-future values,
      # though, will be problems… and we'll fix them! -- rjbs, 2021-11-29
      #
      # (Michael notes that if this is a pain to fix, we can use Future->wrap
      # here.  Legit.)
      my $result = $hit->handle_event($event);
      return unless $result;

      # The retain here should be harmless, but I have low-key anxiety that
      # we're going to end up with a skrillion futures that never go away.  We
      # can add accounting for this another day. -- rjbs, 2021-11-29
      $result->else(sub {
        my (@args) = @_;
        $Logger->log([
          "reaction %s resulted in failure: %s",
          $hit->description,
          "@args", # stupid, but avoids json serialization guff
        ]);

        $event->error_reply("My $rname reactor crashed (in the background) while handling your message.  Sorry!");
      })->retain;
    } catch {
      my $error = $_;

      $error =~ s/\n.*//ms;

      $event->reply("My $rname reactor crashed while handling your message.  Sorry!");
      $Logger->log([
        "error with reaction %s: %s",
        $hit->description,
        $error,
      ]);
    };
  }

  unless ($event->was_handled) {
    return unless $event->was_targeted;

    my @replies = $event->from_user ? $event->from_user->wtf_replies : ();
    @replies = 'Does not compute.' unless @replies;
    $event->error_reply($replies[ rand @replies ]);
    return;
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

  # Force this here, because reactor/channel startup might use it and creating
  # it can be racy (I think).
  $self->http_client;
  $self->server->start;

  $_->start for $self->reactors;
  $_->start for $self->channels;

  if (my $metrics_path = $self->env->metrics_path) {
    $self->server->register_path($metrics_path, $self->prom->psgi, 'the hub');
  }

  $self->_maybe_setup_diagnostic_uplink;
  $self->_setup_diagnostic_metrics_timer;

  return $loop;
}

has diagnostic_uplink => (
  is => 'ro',
  writer => '_set_diagnostic_uplink',
);

sub _maybe_setup_diagnostic_uplink ($self) {
  my $config = $self->env->diagnostic_uplink_config;
  return unless $config;

  require Synergy::DiagnosticUplink;
  my $uplink = Synergy::DiagnosticUplink->new({
    name => 'diagnostic_uplink',
    %$config,
  });
  $uplink->register_with_hub($self);
  $uplink->start;

  $self->_set_diagnostic_uplink($uplink);

  return;
}

sub _setup_diagnostic_metrics_timer ($self) {
  my $prom = $self->prom;
  my $loop = $self->loop;

  $self->prom->declare('synergy_ioasync_notifiers',
    help => 'Number of IO::Async notifiers on the loop',
    type => 'gauge',
  );

  my $diag_timer = IO::Async::Timer::Periodic->new(
    notifier_name => 'diag-metrics',
    interval => 60,
    on_tick  => sub ($timer, @arg) {
      my %notifier_count;
      $notifier_count{ ref $_ }++ for $loop->notifiers;

      for my $class (keys %notifier_count) {
        $prom->set(
          synergy_ioasync_notifiers => $notifier_count{$class},
          { class => $class },
        );
      }
    },
  );

  # We're not keeping a reference to the diagnostic timer, so we can never stop
  # it.  We can address this later, if needed. -- rjbs, 2022-01-05
  $loop->add($diag_timer);

  $diag_timer->start;

  return;
}

sub synergize {
  my $class = shift;
  my ($loop, $config) = @_ == 2 ? @_
                      : @_ == 1 ? (undef, @_)
                      : confess("weird arguments passed to synergize");

  my $channels = delete $config->{channels};
  my $reactors = delete $config->{reactors};

  my $env = Synergy::Environment->new($config);

  $loop //= do {
    require IO::Async::Loop;
    IO::Async::Loop->new;
  };

  my $hub = $class->new({ env => $env });

  for my $pair (
    [ channel => $channels ],
    [ reactor => $reactors ],
  ) {
    my ($thing, $cfg) = @$pair;

    my $plural    = "${thing}s";
    my $register  = "register_$thing";

    for my $name (keys %$cfg) {
      my $thing_config = $cfg->{$name};
      my $thing_class  = delete $thing_config->{class};

      confess "no class given for $thing" unless $thing_class;
      require_module($thing_class);

      my $component = $thing_class->new({
        %$thing_config,
        name => $name,
      });

      $hub->$register($component);
    }
  }

  $hub->set_loop($loop);

  return $hub;
}

sub synergize_file {
  my $class = shift;
  my ($loop, $filename) = @_ == 2 ? @_
                        : @_ == 1 ? (undef, @_)
                        : confess("weird arguments passed to synergize_file");

  return $class->synergize(
    ($loop ? $loop : ()),
    read_config_file($filename),
  );
}

package Synergy::HTTPClient {

  use parent 'Net::Async::HTTP';
}

has http_client => (
  is => 'ro',
  isa => 'Net::Async::HTTP',
  lazy => 1,
  default => sub ($self) {
    my $http = Synergy::HTTPClient->new(
      max_connections_per_host => 5, # seems good?
      max_in_flight => 10,           # default is 4; bump a bit
    );

    $self->loop->add($http);

    return $http;
  },
);

sub http_get {
  return shift->http_request('GET' => @_);
}

sub http_post {
  return shift->http_request('POST' => @_);
}

sub http_put {
  return shift->http_request('PUT' => @_);
}

sub http_delete {
  return shift->http_request('DELETE' => @_);
}

sub http_patch {
  return shift->http_request('PATCH' => @_);
}

sub http_request ($self, $method, $url, %args) {
  my $content = delete $args{Content};
  my $content_type = delete $args{Content_Type};

  my $uri = URI->new($url);

  my @args = (method => $method, uri => $uri);

  if ($method ne 'GET' && $method ne 'HEAD' && $method ne 'DELETE') {
    push @args, defined_kv(content => $content);
  }

  if ($content_type) {
    push @args, content_type => $content_type;
  }

  push @args, headers => \%args;

  if ($uri->scheme eq 'https') {
    # Work around IO::Async::SSL not handling SNI hosts properly :(
    push @args, SSL_hostname => $uri->host;
  }

  # The returned future will run the loop for us until we return. This makes
  # it asynchronous as far as the rest of the code is concerned, but
  # sychronous as far as the caller is concerned.
  my $future = $self->http_client->do_request(
    @args
  )->on_fail(sub {
    my $failure = shift;
    $Logger->log("Failed to $method $url: $failure");
  });

  return $future;
}

1;
