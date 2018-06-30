use v5.24.0;
package Synergy::Reactor::GitLab;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use JSON 2 ();
use MIME::Base64;
use YAML::XS;
use Synergy::Logger '$Logger';

my $JSON = JSON->new->utf8->canonical;

has api_token => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_uri => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has project_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has user_config => (
  is => 'ro',
  isa => 'HashRef',
  traits  => [ 'Hash' ],
  lazy => 1,
  default => sub { {} },
  writer => '_set_user_config',
  handles => {
    set_user  => 'set',
  },
);

around register_with_hub => sub ($orig, $self, @args) {
  $self->$orig(@args);

  if (my $state = $self->fetch_state) {
    $self->_set_user_config($state);
  }
};

sub start ($self) {
  my $timer = IO::Async::Timer::Countdown->new(
    delay => 60,
    on_expire => sub {
      $Logger->log("fetching user config from GitLab");

      my ($ok, $errors) = $self->_reload_all;
      return if $ok;

      $Logger->log([
        "error doing initial user config load from GitLab: %s",
        $errors,
      ]);
    }
  );

  $timer->start;
  $self->hub->loop->add($timer);
}

sub state ($self) { return $self->user_config }

sub listener_specs {
  return {
    name      => 'reload',
    method    => 'handle_reload',
    exclusive => 1,
    predicate => sub ($self, $e) {
      $e->was_targeted &&
      $e->text =~ /^reload\s+(?:my|all user)?\s+config(\s|$)/in;
    },
  };
}

sub handle_reload ($self, $event) {
  $event->mark_handled;

  return $event->reply("Sorry, I don't know who you are.")
    unless $event->from_user;

  my $text = $event->text;
  my ($what) = $text =~ /^\s*reload\s+(.*)/i;
  $what &&= lc $what;

  $what =~ s/^\s*|\s*$//g;

  return $self->handle_my_config($event)  if $what eq 'my config';
  return $self->handle_all_config($event) if $what eq 'all user config';

  return $event->reply("I don't know how to reload <$what>");
}

sub handle_my_config ($self, $event) {
  my $username = $event->from_user->username;
  my ($ok, $error) = $self->_update_user_config($username);

  return $event->reply("your configuration has been reloaded") if $ok;
  return $event->reply("error reloading config: $error");
}

sub handle_all_config ($self, $event) {
  return $event->reply("Sorry, only the master user can do that")
    unless $event->from_user->is_master;

  my ($ok, $errors) = $self->_reload_all;
  return $event->reply("user config reloaded") if $ok;

  my $who = join ', ', sort @$errors;
  return $event->reply("encounted errors while reloading following users: $who");
}

sub _reload_all ($self) {
  my @errors;

  for my $username ($self->hub->user_directory->usernames) {
    my ($ok, $error) = $self->_update_user_config($username);
    next if $ok;

    push @errors, "$username: $error";
    $Logger->log([
      "error while fetching user config for %s: %s",
      $username,
      $error
    ]);
  }

  return (1, undef) unless @errors;
  return (0, \@errors);
}

sub _update_user_config ($self, $username) {
  my $url = sprintf("%s/v4/projects/%s/repository/files/%s.yaml?ref=master",
    $self->api_uri,
    $self->project_id,
    $username,
  );

  my $res = $self->hub->http_get(
    $url,
    'PRIVATE-TOKEN' => $self->api_token,
  );

  unless ($res->is_success) {
    if ($res->code == 404) {
      $self->hub->user_directory->reload_user($username, {});
      return (undef, "no config in git");
    }

    $Logger->log([ "Error: %s", $res->as_string ]);
    return (undef, "error retrieving config")
  }

  my $content = eval {
    decode_base64( $JSON->decode( $res->decoded_content )->{content} );
  };

  return (undef, "error with GitLab response") unless $content;

  my $uconfig = eval { YAML::XS::Load($content) };
  return (undef, "error with YAML in config") unless $uconfig;

  $self->hub->user_directory->reload_user($username, $uconfig);
  $self->hub->load_preferences_from_user($username);
  $self->set_user($username => $uconfig);
  $self->save_state;
  return (1, undef);
}

1;
