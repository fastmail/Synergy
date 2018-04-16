use v5.24.0;
package Synergy::Hub;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

use Synergy::Logger '$Logger';

use DBI;
use JSON::MaybeXS;
use Module::Runtime qw(require_module);
use Synergy::UserDirectory;
use Path::Tiny ();
use Plack::App::URLMap;
use Synergy::HTTPServer;
use Try::Tiny;

has user_directory => (
  is  => 'ro',
  isa => 'Object',
  required  => 1,
);

has state_dbfile => (
  is  => 'ro',
  isa => 'Str',
  lazy => 1,
  default => "synergy.sqlite",
);

has _state_dbh => (
  is  => 'ro',
  init_arg => undef,
  default  => sub ($self, @) {
    my $dbf = $self->state_dbfile;

    my $dbh = DBI->connect(
      "dbi:SQLite:dbname=$dbf",
      undef,
      undef,
      { RaiseError => 1 },
    );
    die $DBI::errstr unless $dbh;

    $dbh->do(q{
      CREATE TABLE IF NOT EXISTS synergy_state (
        reactor_name TEXT PRIMARY KEY,
        stored_at INTEGER NOT NULL,
        json TEXT NOT NULL
      );
    });

    return $dbh;
  },
);

sub save_state ($self, $reactor, $state) {
  my $json = eval { JSON::MaybeXS->new->encode($state) };

  unless ($json) {
    $Logger->log([ "error serializing state for %s: %s", $reactor->name, $@ ]);
    return;
  }

  $self->_state_dbh->do(
    "INSERT OR REPLACE INTO synergy_state (reactor_name, stored_at, json)
    VALUES (?, ?, ?)",
    undef,
    $reactor->name,
    time,
    $json,
  );

  return 1;
}

sub fetch_state ($self, $reactor) {
  my ($json) = $self->_state_dbh->selectrow_array(
    "SELECT json FROM synergy_state WHERE reactor_name = ?",
    undef,
    $reactor->name,
  );

  return unless $json;
  return JSON::MaybeXS->new->decode($json);
}

has server_port => (
  is => 'ro',
  isa => 'Int',
  default => 8118,
);

has server => (
  is => 'ro',
  isa => 'Synergy::HTTPServer',
  lazy => 1,
  default => sub ($self) {
    my $s = Synergy::HTTPServer->new({
      server_port => $self->server_port,
    });

    $s->register_with_hub($self);
    return $s;
  },
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
  $Logger->log([
    "%s event from %s/%s: %s",
    $event->type,
    $event->from_channel->name,
    $event->from_user ? 'u:' . $event->from_user->username : $event->from_address,
    $event->text,
  ]);

  my @hits;
  for my $reactor ($self->reactors) {
    for my $listener ($reactor->listeners) {
      next unless $listener->matches_event($event);
      push @hits, [ $reactor, $listener ];
    }
  }

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

      my $rname = $reactor->name;

      $rch->reply("My $rname reactor crashed while handling your message.  Sorry!");
      $Logger->log([
        "error with %s listener on %s: %s",
        $hit->[1]->name,
        $reactor->name,
        $error,
      ]);
    };
  }

  unless ($event->was_handled) {
    return unless $event->was_targeted;

    my @replies = $event->from_user ? $event->from_user->wtf_replies : ();
    @replies = 'Does not compute.' unless @replies;

    $rch->reply($replies[ rand @replies ]);
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

  $self->server->start;

  $_->start for $self->channels;
  $_->start for $self->reactors;

  return $loop;
}

sub synergize {
  my $class = shift;
  my ($loop, $config) = @_ == 2 ? @_
                      : @_ == 1 ? (undef, @_)
                      : confess("weird arguments passed to synergize");

  $loop //= do {
    require IO::Async::Loop;
    IO::Async::Loop->new;
  };

  # config:
  #   directory: source file
  #   channels: name => config
  #   reactors: name => config
  #   http_server: (port => id)
  #   state_directory: ...
  my $directory = Synergy::UserDirectory->new;

  if ($config->{user_directory}) {
    $directory->load_users_from_file($config->{user_directory});
  }

  my $hub = $class->new({
    user_directory => $directory,
    ($config->{server_port} ? (server_port => $config->{server_port}) : ()),
  });

  for my $thing (qw( channel reactor )) {
    my $plural    = "${thing}s";
    my $register  = "register_$thing";

    for my $thing_name (keys %{ $config->{$plural} }) {
      my $thing_config = $config->{$plural}{$thing_name};
      my $thing_class  = delete $thing_config->{class};

      confess "no class given for $thing" unless $thing_class;
      require_module($thing_class);

      my $thing = $thing_class->new({
        %{ $thing_config },
        name => $thing_name,
      });

      $hub->$register($thing);
    }
  }

  $hub->set_loop($loop);

  return $hub;
}

sub _slurp_json_file ($filename) {
  my $file = Path::Tiny::path($filename);
  confess "config file does not exist" unless -e $file;
  my $json = $file->slurp_utf8;
  return JSON::MaybeXS->new->decode($json);
}

sub synergize_file {
  my $class = shift;
  my ($loop, $filename) = @_ == 2 ? @_
                        : @_ == 1 ? (undef, @_)
                        : confess("weird arguments passed to synergize_file");

  my $reader  = $filename =~ /\.ya?ml\z/ ? sub { YAML::XS::LoadFile($_[0]) }
              : $filename =~ /\.json\z/  ? \&_slurp_json_file
              : confess "don't know how to synergize_file $filename";

  return $class->synergize(
    ($loop ? $loop : ()),
    $reader->($filename),
  );
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

sub http_post {
  return shift->http_request('POST' => @_);
}

sub http_put {
  return shift->http_request('PUT' => @_);
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
    $Logger->log("Failed to $method $url: $failure");
  } )->get;
}

1;
