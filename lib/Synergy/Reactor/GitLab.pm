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

sub start ($self) {
  my ($ok, $errors) = $self->_reload_all;
  return if $ok;

  $Logger->log([
    "error doing initial user config load from GitLab: %s",
    $errors,
  ]);
}

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

sub handle_reload ($self, $event, $rch) {
  $event->mark_handled;

  return $rch->reply("Sorry, I don't know who you are.")
    unless $event->from_user;

  my $text = $event->text;
  my ($what) = $text =~ /^\s*reload\s+(.*)/;
  $what &&= lc $what;

  $what =~ s/^\s*|\s*$//g;

  return $self->handle_my_config($event, $rch)  if $what eq 'my config';
  return $self->handle_all_config($event, $rch) if $what eq 'all user config';

  return $rch->reply("I don't know how to reload <$what>");
}

sub handle_my_config ($self, $event, $rch) {
  my $username = $event->from_user->username;
  my ($ok, $error) = $self->_update_user_config($username);

  return $rch->reply("your configuration has been reloaded") if $ok;
  return $rch->reply("error reloading config: $error");
}

sub handle_all_config ($self, $event, $rch) {
  return $rch->reply("Sorry, only the master user can do that")
    unless $event->from_user->is_master;

  my ($ok, $errors) = $self->_reload_all;
  return $rch->reply("user config reloaded") if $ok;

  my $who = join ', ', sort @$errors;
  return $rch->reply("encounted errors while reloading following users: $who");
}

sub _reload_all ($self) {
  my @errors;

  for my $username ($self->hub->user_directory->usernames) {
    my ($ok, $error) = $self->_update_user_config($username);
    next if $ok;

    push @errors, $username;
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
  return (1, undef);
}

1;
