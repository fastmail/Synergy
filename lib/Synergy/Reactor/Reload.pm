use v5.24.0;
package Synergy::Reactor::Reload;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use JSON 2 ();
use List::Util qw(first);
use MIME::Base64;
use YAML::XS;
use Synergy::Logger '$Logger';
use Data::Dumper::Concise;

my $JSON = JSON->new->canonical;

has lp_reactor_name => (
  is => 'ro',
  isa => 'Str',
);

has gitlab_token => (
  is => 'ro',
  isa => 'Str',
);

my $GITLAB_BASE = "https://git.messagingengine.com/api/v4";
my $GITLAB_PROJECT_ID = 335;

sub listener_specs {
  return ( {
    name      => 'reload',
    method    => 'dispatch_event',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^reload(\s|$)/i },
  },
  {
    name => 'dump-user',
    method => 'dump_user',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^dump(\s|$)/i },

  },
  );
}

sub dump_user ($self, $event, $rch) {
  $event->mark_handled;
  my $user = $event->from_user;
  warn Dumper $user;
};

sub dispatch_event ($self, $event, $rch) {
  $event->mark_handled;

  return $rch->reply("Sorry, I don't know who you are.")
    unless $event->from_user;

  my $text = $event->text;
  my ($what) = $text =~ /^\s*reload\s+(.*)/;
  $what &&= lc $what;

  $what =~ s/^\s*|\s*$//g;

  return $self->handle_projects($event, $rch)   if $what eq 'projects';
  return $self->handle_my_config($event, $rch)  if $what eq 'my config';
  return $self->handle_all_config($event, $rch) if $what eq 'all user config';

  # It's not handled yet, but it will have been by the time we return!
  return $rch->reply("I don't know how to reload <$what>");
}

sub handle_projects ($self, $event, $rch) {
  return $rch->reply("I don't seem to have a liquid-planner reactor")
    unless $self->lp_reactor_name;

  my $lp = $self->hub->reactor_named($self->lp_reactor_name);
  $lp->_set_projects($lp->get_project_nicknames);

  $rch->reply("Projects reloaded");
}

sub handle_my_config ($self, $event, $rch) {
  return $rch->reply("I don't seem to have a gitlab token")
    unless $self->gitlab_token;

  my $username = $event->from_user->username;
  my ($ok, $error) = $self->_update_user_config($username);

  return $rch->reply("your configuration has been reloaded") if $ok;
  return $rch->reply("error reloading config: $error");
}

sub handle_all_config ($self, $event, $rch) {
  return $rch->reply("I don't seem to have a gitlab token")
    unless $self->gitlab_token;

  return $rch->reply("Sorry, only the master user can do that")
    unless $event->from_user->is_master;

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

  return $rch->reply("user config reloaded") unless @errors;

  my $who = join ', ', sort @errors;
  return $rch->reply("encounted errors while reloading following users: $who");
}

sub _update_user_config ($self, $username) {
  my $url = sprintf("%s/projects/%s/repository/files/%s.yaml?ref=master",
    $GITLAB_BASE,
    $GITLAB_PROJECT_ID,
    $username,
  );

  my $res = $self->hub->http_get(
    $url,
    'PRIVATE-TOKEN' => $self->gitlab_token,
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
