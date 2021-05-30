use v5.24.0;
use warnings;
package Synergy::Reactor::Vestaboard;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';
with 'Synergy::Role::HTTPEndpoint';

use experimental qw(signatures);
use namespace::clean;

use Data::GUID qw(guid_string);
use Plack::Request;
use URI;
use URI::QueryParam;

sub listener_specs {
  return {
    name      => 'vesta_edit',
    method    => 'handle_vesta_edit',
    exclusive => 1,
    predicate => sub ($, $e) { $e->was_targeted && lc $e->text eq 'vesta edit' },
    help_entries => [
      {
        title => 'vesta',
        text  => "**vesta edit**: edit what is on the vestaboard",
      }
    ],
  };
}

has '+http_path' => (
  default => sub {
    my ($self) = @_;
    return '/vesta/' . $self->name;
  },
);

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

  if ($req->path eq '/editor') {
    if ($req->path eq 'POST') {
      my $username = $req->parameters->{username}; # yeah yeah, multivalue…
      my $secret   = $req->parameters->{secret};
      my $save_as  = $req->parameters->{name};
      my $design   = $req->parameters->{characters};

      my $user     = $self->hub->user_directory->user_named($username);
      my $is_valid = $user && $self->_validate_secret_for($user, $secret);

      unless ($is_valid) {
        return [
          403,
          [ "Content-Type" => "application/json" ],
          [ qq({ "error": "authentication failed" }\n) ],
        ];
      }

      unless ($self->_validate_design($design)) {
        return [
          400,
          [ "Content-Type" => "application/json" ],
          [ qq({ "error": "invalid design" }\n) ],
        ];
      }

      # This is stupid, but should get the job done. -- rjbs, 2021-05-30
      my $name = length $save_as ? $save_as : ("design " . time);
      $name =~ s/[^\pL\pN\pM]/-/g;
      $name =~ s/-{2,}/-/g;

      my $this_user_state = $self->_user_state->{ $username } //= {};
      $this_user_state->{designs}{$name} = $design;
      $self->save_state;

      if ($self->default_channel_name) {
        my $channel = $self->hub->channel_named($self->default_channel_name);
        $channel->send_message_to_user($user, "I've saved a new board design called `$name`.");
      }

      return [
        200,
        [ "Content-Type" => "application/json" ],
        [ qq({ "ok": true }\n) ],
      ];
    } else {
      # Serve the editor.
      return [
        200,
        [ "Content-Type" => "text/plain" ],
        [ "This does not yet work.\n" ],
      ];
    }
  }

  return [
    404,
    [ 'Content-Type' => 'text/plain' ],
    [ "Sorry, nothing here." ],
  ];
}

sub _validate_design ($self, $design) {
  # This is not doing enough. -- rjbs, 2021-05-30
  return unless $design;
  return unless @$design == 6;
  for (@$design) { return unless @$_ == 22; }
  return 1;
}

# Reactor state:
#   lock: undef | { by: USERNAME, expires_at: null | EPOCH-SEC }
#   user:
#     ${username}:
#       tokens: COUNT
#       next_token: EPOCH-SEC
#       designs: { NAME: DESIGN }
#       secret: { expires_at: EPOCH-SEC, value: STRING }

sub state ($self) {
  return {
    user  => { $self->_user_state },
    lock  => $self->_lock_state,
  };
}

has default_channel_name => (
  is  => 'ro',
  isa => 'Str',
);

has editor_uri => (
  is => 'ro',
  required => 1,
);

has _user_state => (
  is      => 'ro',
  writer  => '_set_user_state',
  default => sub {  {}  },
);

has _lock_state => (
  is      => 'ro',
  writer  => '_set_lock_state',
  default => sub {  {}  },
);

sub is_locked ($self) {
  my $lock = $self->_lock_state;

  # No lock.
  return if keys %$lock == 0;

  # Unexpired lock.
  return 1 if ($self->_lock_state->{expires_at} // 0) > time;

  # Expired lock.  Empty the lock, save state, and return false.
  $self->_set_lock_state({});
  $self->save_state;

  return;
}

after register_with_hub => sub ($self, @) {
  if ( $self->default_channel_name
    && ! $self->hub->channel_named($self->default_channel_name)
  ) {
    Carp::confess("invalid configuration: can't find default channel");
  }

  if (my $state = $self->fetch_state) {
    $self->_set_user_state($state->{user});
    $self->_set_lock_state($state->{lock});
  }
};

sub handle_vesta_edit ($self, $event) {
  my $text = $event->text;

  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  if ($event->is_public) {
    $event->reply("I'll send you a link to edit the Vestaboard in private.");
  }

  my $secret = $self->_secret_for($user);
  my $uri    = URI->new($self->editor_uri);
  $uri->query_param(u => $user->username);
  $uri->query_param(secret => $secret);

  $event->private_reply(
    "Okay, time to get editing! Click here: $uri",
    {
      slack => sprintf(
        "Okay, head over to <%s|the Vestaboard editor>!",
        "$uri",
      ),
    },
  );

  return;
}

my $MAX_SECRET_AGE = 1800;

sub _validate_secret_for ($self, $user, $secret) {
  my $hashref = $self->_user_state->{ $user->username };

  return unless $hashref;

  return unless $hashref->{expires_at} > time;

  return unless $hashref->{value} eq $secret;

  return 1;
}

sub _secret_for ($self, $user) {
  my $hashref = $self->_user_state->{ $user->username } //= {};

  if (($hashref->{expires_at} // 0) <= time) {
    $hashref->{value} = lc guid_string;
  }

  $hashref->{expires_at} = time + $MAX_SECRET_AGE;

  $self->save_state;

  return $hashref->{value};
}

1;
