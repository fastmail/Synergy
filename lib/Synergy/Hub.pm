use v5.24.0;
use warnings;
package Synergy::Hub;

use Moose;
use MooseX::StrictConstructor;

use experimental qw(signatures);
use namespace::clean;

use Synergy::Logger '$Logger';

use DBI;
use JSON::MaybeXS;
use YAML::XS;
use TOML;
use Module::Runtime qw(require_module);
use Synergy::UserDirectory;
use Path::Tiny ();
use Plack::App::URLMap;
use Synergy::HTTPServer;
use Try::Tiny;
use URI;
use Scalar::Util qw(blessed);
use Defined::KV;

has name => (
  is  => 'ro',
  isa => 'Str',
  default => 'Synergy',
);

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
  lazy => 1,
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

    $dbh->do(q{
      CREATE TABLE IF NOT EXISTS users (
        username TEXT PRIMARY KEY,
        lp_id TEXT,
        is_master INTEGER DEFAULT 0,
        is_virtual INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0
      );
    });

    $dbh->do(q{
      CREATE TABLE IF NOT EXISTS user_identities (
        id INTEGER PRIMARY KEY,
        username TEXT NOT NULL,
        identity_name TEXT NOT NULL,
        identity_value TEXT NOT NULL,
        FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE,
        CONSTRAINT constraint_username_identity UNIQUE (username, identity_name),
        UNIQUE (identity_name, identity_value)
      );
    });

    return $dbh;
  },
);

sub save_state ($self, $reactor, $state) {
  my $json = eval { JSON::MaybeXS->new->utf8->encode($state) };

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
  return JSON::MaybeXS->new->utf8->decode($json);
}

has server_port => (
  is => 'ro',
  isa => 'Int',
  default => 8118,
);

has tls_cert_file => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has tls_key_file => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has server => (
  is => 'ro',
  isa => 'Synergy::HTTPServer',
  lazy => 1,
  default => sub ($self) {
    my $s = Synergy::HTTPServer->new({
      name          => '_http_server',
      server_port   => $self->server_port,
      tls_cert_file => $self->tls_cert_file,
      tls_key_file  => $self->tls_key_file,
    });

    $s->register_with_hub($self);
    return $s;
  },
);

my %channel_and_reactor_names;

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

      if (my $what = $channel_and_reactor_names{$name}) {
        confess("$what named '$name' exists: cannot register $s named '$name'");
      }

      $channel_and_reactor_names{$name} = $s;

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

# Temporary, so that we can slowly convert git config to proper preferences.
sub load_preferences_from_user ($self, $user) {
  my $username = blessed $user ? $user->username : $user;
  for my $component ($self->user_directory, $self->channels, $self->reactors) {
    next unless $component->has_preferences;
    next unless $component->can('load_preferences_from_user');
    $component->load_preferences_from_user($username);
  }
}

sub handle_event ($self, $event) {
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
    my @names = sort map {; join q{},
      $_->[1]->is_exclusive ? ('**') : (),
      $_->[0]->name, '/', $_->[1]->name,
      $_->[1]->is_exclusive ? ('**') : (),
    } @hits;
    $event->error_reply("Sorry, I find that message ambiguous.\n" .
                    "The following reactors matched: " . join(", ", @names));
    return;
  }

  for my $hit (@hits) {
    my $reactor = $hit->[0];
    my $method  = $hit->[1]->method;

    try {
      $reactor->$method($event);
    } catch {
      my $error = $_;

      $error =~ s/\n.*//ms;

      my $rname = $reactor->name;

      $event->reply("My $rname reactor crashed while handling your message.  Sorry!");
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

  $self->server->start;

  $_->start for $self->reactors;
  $_->start for $self->channels;

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
  my $directory = Synergy::UserDirectory->new({ name => '_user_directory' });

  my $hub = $class->new({
    user_directory  => $directory,
    defined_kv(time_zone_names => $config->{time_zone_names}),
    defined_kv(server_port     => $config->{server_port}),
    defined_kv(tls_cert_file   => $config->{tls_cert_file}),
    defined_kv(tls_key_file    => $config->{tls_key_file}),
    defined_kv(state_dbfile    => $config->{state_dbfile}),
  });

  $directory->register_with_hub($hub);
  $directory->load_users_from_database;

  if ($config->{user_directory}) {
    $directory->load_users_from_file($config->{user_directory});
  }

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

  # Everything's all registered...give them a chance to load up user prefs
  # before calling ->start.
  $hub->load_preferences_from_user($_) for $hub->user_directory->users;

  $hub->set_loop($loop);

  return $hub;
}

sub _slurp_json_file ($filename) {
  my $file = Path::Tiny::path($filename);
  confess "config file does not exist" unless -e $file;
  my $json = $file->slurp_utf8;
  return JSON::MaybeXS->new->decode($json);
}

sub _slurp_toml_file ($filename) {
  my $file = Path::Tiny::path($filename);
  confess "config file does not exist" unless -e $file;
  my $toml = $file->slurp_utf8;
  my ($data, $err) = from_toml($toml);
  unless ($data) {
    die "Error parsing toml file $filename: $err\n";
  }
  return $data;
}

sub synergize_file {
  my $class = shift;
  my ($loop, $filename) = @_ == 2 ? @_
                        : @_ == 1 ? (undef, @_)
                        : confess("weird arguments passed to synergize_file");

  my $reader  = $filename =~ /\.ya?ml\z/ ? sub { YAML::XS::LoadFile($_[0]) }
              : $filename =~ /\.json\z/  ? \&_slurp_json_file
              : $filename =~ /\.toml\z/  ? \&_slurp_toml_file
              : confess "don't know how to synergize_file $filename";

  return $class->synergize(
    ($loop ? $loop : ()),
    $reader->($filename),
  );
}

has http_client => (
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

sub http_delete {
  return shift->http_request('DELETE' => @_);
}

sub http_request ($self, $method, $url, %args) {
  my $content = delete $args{Content};
  my $content_type = delete $args{Content_Type};
  my $async = delete $args{async};

  my $uri = URI->new($url);

  my @args = (method => $method, uri => $uri);

  if ($method ne 'GET' && $method ne 'HEAD' && $method ne 'DELETE') {
    push @args, (content => $content // []);
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
  )->on_fail( sub {
    my $failure = shift;
    $Logger->log("Failed to $method $url: $failure");
  } );

  return $async ? $future : $future->get;
}

has time_zone_names => (
  is  => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

sub format_friendly_date ($self, $dt, $arg = {}) {
  # arg:
  #   now               - a DateTime to use for now, instead of actually now
  #   allow_relative    - can we use relative stuff? default true
  #   include_time_zone - default true
  #   maybe_omit_day    - default false; if true, skip "today at" on today
  #   target_time_zone  - format into this time zone; default, $dt's TZ

  if ($arg->{target_time_zone} && $arg->{target_time_zone} ne $dt->time_zone->name) {
    $dt = DateTime->from_epoch(
      time_zone => $arg->{target_time_zone},
      epoch => $dt->epoch,
    );
  }

  my $now = $arg->{now}
          ? $arg->{now}->clone->set_time_zone($dt->time_zone)
          : DateTime->now(time_zone => $dt->time_zone);

  my $dur = $now->subtract_datetime($dt);
  my $tz_str = $self->time_zone_names->{ $dt->time_zone->name }
            // $dt->format_cldr('vvv');

  my $at_time = "at "
              . $dt->format_cldr('HH:mm')
              . (($arg->{include_time_zone}//1) ? " $tz_str" : "");

  if (abs($dur->delta_months) > 11) {
    return $dt->format_cldr('MMMM d, YYYY') . " $at_time";
  }

  if ($dur->delta_months) {
    return $dt->format_cldr('MMMM d') . " $at_time";
  }

  my $days = $dur->delta_days;

  if (abs $days >= 7 or ! ($arg->{allow_relative}//1)) {
    return $dt->format_cldr('MMMM d') . " $at_time";
  }

  my %by_day = (
    -2 => "the day before yesterday $at_time",
    -1 => "yesterday $at_time",
    +0 => "today $at_time",
    +1 => "tomorrow $at_time",
    +2 => "the day after tomorrow $at_time",
  );

  for my $offset (sort { $a <=> $b } keys %by_day) {
    return $by_day{$offset}
      if $dt->ymd eq $now->clone->add(days => $offset)->ymd;
  }

  my $which = $dur->is_positive ? "this past" : "this coming";
  return join q{ }, $which, $dt->format_cldr('EEEE'), $at_time;
}

1;
