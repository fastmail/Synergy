use v5.32.0;
use warnings;
package Synergy::Reactor::Vestaboard;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';
with 'Synergy::Role::HTTPEndpoint';

use experimental qw(signatures);
use namespace::clean;

use Data::GUID qw(guid_string);
use Lingua::EN::Inflect qw(NUMWORDS PL_N);
use MIME::Base64 ();
use Path::Tiny;
use Plack::App::File;
use Plack::Request;
use Synergy::VestaUtil;
use Time::Duration;
use Unicode::Normalize qw(NFD);
use URI;
use URI::QueryParam;

use Synergy::Logger '$Logger';

my $MAX_SECRET_AGE  = 1800;

has max_token_count => (
  is => 'ro',
  default => 1,
);

has token_regen_period => (
  is => 'ro',
  default => 6 * 3600,
);

has asset_directory => (
  is => 'ro',
  required => 1,
);

has board_admins => (
  isa => 'ArrayRef',
  default => sub {  []  },
  traits  => [ 'Array' ],
  handles => {
    board_admins => 'elements',
  },
);

has vesta_image_base => (
  is => 'ro',
);

has secret_url_component => (
  is => 'ro',
);

has is_simulation => (
  is => 'ro',
);

sub listener_specs {
  return (
    {
      name      => 'vesta_edit',
      method    => 'handle_vesta_edit',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { lc $e->text =~ /\Avesta edit /i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta edit `DESIGN`*: edit what is on the vestaboard",
        }
      ],
    },
    {
      name      => 'vesta_delete_design',
      method    => 'handle_vesta_delete_design',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { lc $e->text =~ /\Avesta delete design / },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta delete design `DESIGN`*: delete one of your designs",
        }
      ],
    },
    {
      name      => 'vesta_designs',
      method    => 'handle_vesta_designs',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { lc $e->text eq 'vesta designs' },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta designs*: list all your designs",
        }
      ],
    },
    {
      name      => 'vesta_post_text',
      method    => 'handle_vesta_post_text',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta post text:? .+\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta post text `TEXT`*: post a text message to the board",
        }
      ],
    },
    {
      name      => 'vesta_random_colors',
      method    => 'handle_vesta_random_colors',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta random\s+colou?rs/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta random colors*: post random colo(u)rs to the board",
        }
      ],
    },
    {
      name      => 'vesta_post',
      method    => 'handle_vesta_post',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta post \S+\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta post `DESIGN`*: post your design to the board",
        }
      ],
    },
    {
      name      => 'vesta_status',
      method    => 'handle_vesta_status',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta status\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta status*: check the board status and your token count",
        }
      ],
    },
    {
      name      => 'vesta_show_text',
      method    => 'handle_vesta_show_text',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta show text /i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta show text `TEXT`*: show a preview of given text",
        }
      ],
    },
    {
      name      => 'vesta_show_design',
      method    => 'handle_vesta_show_design',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta show design /i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta show design `DESIGN`*: show a preview of one of your designs",
        }
      ],
    },
    {
      name      => 'vesta_show',
      method    => 'handle_vesta_show',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta show\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta show*: see what's on the board",
        }
      ],
    },
    {
      name      => 'vesta_lock',
      method    => 'handle_vesta_lock',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta (un)?lock\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta lock/unlock*: (admins only) lock or unlock the board",
        }
      ],
    },
    {
      name      => 'vesta_grant',
      method    => 'handle_vesta_grant',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Avesta grant/i },
    },
  );
}

has [ qw( subscription_id api_key api_secret ) ] => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has '+http_path' => (
  default => sub {
    my ($self) = @_;
    return '/vesta/' . $self->name;
  },
);

sub _handle_post ($self, $req) {
  my $payload = eval { JSON::MaybeXS->new->decode($req->content); };

  unless ($payload) {
    return [
      400,
      [ "Content-Type" => "application/json" ],
      [ qq({ "error": "garbled payload" }\n) ],
    ];
  }

  state $i = 1;
  my $username = $payload->{username};
  my $secret   = $payload->{secret};
  my $design   = $payload->{board};

  # This idiotic fallback is just in case I have done something else idiotic
  # somewhere that causes us to almost drop a design on the floor.
  # -- rjbs, 2021-05-31
  my $save_as  = $payload->{design} // join q{.}, $i++, $^T;

  my $user     = $username && $self->hub->user_directory->user_named($username);
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

  my $name_key = NFD(fc $name);

  my $this_user_state = $self->_user_state->{ $username } //= {};
  $this_user_state->{designs}{$name_key} = {
    name       => $name,
    characters => $design,
  };

  $self->save_state;

  $Logger->log("Saved new design <$name> for $username");

  if ($self->default_channel_name) {
    my $channel = $self->hub->channel_named($self->default_channel_name);
    $channel->send_message_to_user($user, "I've updated a board design called `$name`.");
  }

  return [
    200,
    [ "Content-Type" => "application/json" ],
    [ qq({ "ok": true }\n) ],
  ];
}

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

  if ($req->path_info eq '') {
    # We need to use .../ and not ... so that relative URLs in the editor
    # source resolve properly!
    return [
      307,
      [ Location => $req->uri . "/" ],
      []
    ];
  }

  if ($req->method eq 'POST') {
    unless ($req->path_info eq '/') {
      return [
        400,
        [ 'Content-Type' => 'text/plain' ],
        [ "Bad method." ]
      ];
    }

    return $self->_handle_post($req);
  }

  # Not a POST, act like GET.
  if ($req->path_info eq '/') {
    $Logger->log("Serving raw editor");

    open my $fh, '<', join(q{/}, $self->asset_directory, 'index.html');
    return [
      200,
      [ "Content-Type" => "text/html; charset=utf-8" ],
      $fh,
    ];
  }

  my $res_404 = [
    404,
    [ 'Content-Type' => 'text/plain' ],
    [ "Not found." ],
  ];

  my $path_info = $req->path_info;
  unless ($path_info =~ s{\A/}{}) {
    # What the heck was that?  Well, it's not /vesta/us/foo-like, so just call
    # it 404 and move on. -- rjbs, 2021-12-31
    return $res_404;
  }

  if (my $secret = $self->secret_url_component) {
    if ($path_info eq $secret) {
      my $curr = $self->_current_characters;
      return $res_404 unless $curr;

      return [
        200,
        [
          'Content-Type', 'application/json',
        ],
        [ JSON::MaybeXS->new->encode($curr) ],
      ];
    }

    if ($path_info eq "$secret/current") {
      return $res_404 unless $self->vesta_image_base;

      my $curr = $self->_current_characters;
      return $res_404 unless $curr;

      my $url = join q{/},
                ($self->vesta_image_base =~ s{/\z}{}r),
                Synergy::VestaUtil->encode_board($curr);

      return [
        302,
        [
          'Location', $url
        ],
        [ ],
      ];
    }
  }

  my $asset_dir = eval { path($self->asset_directory)->realpath };
  my $wanted    = eval { $asset_dir->child($path_info)->realpath };

  return $res_404 unless $asset_dir && $wanted;
  return $res_404 unless $asset_dir->subsumes($wanted);
  return $res_404 unless -e $wanted;

  open my $fh, '<', $wanted or die "can't read asset file $wanted: $!";

  return [
    200,
    [
      'Content-Type', Plack::MIME->mime_type($wanted),
    ],
    $fh,
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
#       tokens: { count: COUNT, next: EPOCH-SEC }
#       designs: { NAMEKEY: { characters: GRID, name: NAME }
#       secret: { expires_at: EPOCH-SEC, value: STRING }

sub state ($self) {
  return {
    user  => $self->_user_state,
    lock  => $self->_lock_state,
    current_characters => $self->_current_characters,
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

has _current_characters => (
  is      => 'ro',
  writer  => '_set_current_characters',
  default => sub {  [ [], [], [], [], [], [] ] },
);

sub current_lock ($self) {
  my $lock = $self->_lock_state;

  # No lock.
  return if keys %$lock == 0;

  # Unexpired lock.
  return $lock if ($self->_lock_state->{expires_at} // 0) > time;

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
    $self->_set_current_characters($state->{current_characters})
      if $self->_current_characters;
  }

  return;
};

sub handle_vesta_show ($self, $event) {
  $event->mark_handled;

  my $curr = $self->_current_characters;

  unless ($curr) {
    return $event->reply("Sorry, I don't know what's on the board!");
  }

  if ($self->vesta_image_base) {
    my $url = join q{/},
              ($self->vesta_image_base =~ s{/\z}{}r),
              Synergy::VestaUtil->encode_board($curr);

    return $event->reply(
      "The current board status is: $url",
      {
        slack => sprintf("Enjoy <%s|the current board status!>", $url),
      },
    );
  }

  my $display = Synergy::VestaUtil->board_to_text($curr);
  my $reply   = "Currently on the board:\n$display";

  my $whitespace = "\N{WHITE LARGE SQUARE}";

  $event->reply(
    $reply,
    {
      slack => ($reply =~ s/$whitespace/:spacer:/gr)
    }
  );
}

sub handle_vesta_show_text ($self, $event) {
  $event->mark_handled;

  my $text = $event->text;
  $text =~ s/\Avesta show text\s+//;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  my ($board, $error) = Synergy::VestaUtil->text_to_board($text);

  unless ($board) {
    return $event->error_reply("Sorry, I can't find that design!");
  }

  if ($self->vesta_image_base) {
    my $url = join q{/},
              ($self->vesta_image_base =~ s{/\z}{}r),
              Synergy::VestaUtil->encode_board($board),
              'cropped';

    return $event->reply(
      "You can see that design at: $url",
      {
        slack => sprintf("Behold, <%s|your text>", $url),
      },
    );
  }

  my $display = Synergy::VestaUtil->board_to_text($board);
  my $reply   = "Your text:\n$display";

  my $whitespace = "\N{WHITE LARGE SQUARE}";

  $event->reply(
    $reply,
    {
      slack => ($reply =~ s/$whitespace/:spacer:/gr)
    }
  );
}

sub handle_vesta_show_design ($self, $event) {
  $event->mark_handled;

  my $text = $event->text;
  my $name = $text =~ s/\Avesta show design\s+//r;
  $name =~ s/[^\pL\pN\pM]/-/g;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  my $design = $self->_get_user_design_named($user, $name);

  unless ($design) {
    return $event->error_reply("Sorry, I can't find that design!");
  }

  my $board = $design->{characters};

  if ($self->vesta_image_base) {
    my $url = join q{/},
              ($self->vesta_image_base =~ s{/\z}{}r),
              Synergy::VestaUtil->encode_board($board),
              'cropped';

    return $event->reply(
      "You can see that design at: $url",
      {
        slack => sprintf("Behold, your design <%s|%s>", $url, $design->{name}),
      },
    );
  }

  my $display = Synergy::VestaUtil->board_to_text($board);
  my $reply   = "Your design $design->{name}:\n$display";

  my $whitespace = "\N{WHITE LARGE SQUARE}";

  $event->reply(
    $reply,
    {
      slack => ($reply =~ s/$whitespace/:spacer:/gr)
    }
  );
}

sub handle_vesta_lock ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I can't help you out!");
  }

  unless (grep {; $_ eq $user->username } $self->board_admins) {
    return $event->error_reply("Sorry, only board admins can lock or unlock the board");
  }

  if ($event->text =~ /vesta unlock/i) {
    $self->_set_lock_state({});
    $self->save_state;
    return $event->reply("The board is now unlocked!");
  }

  $self->_set_lock_state({
    locked_by   => $user->username,
    expires_at  => time + 2*86_400, # two days is probably a good default?
  });

  $self->save_state;

  return $event->reply("The board is locked!  Don't forget to unlock it later.");
}

sub handle_vesta_grant ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I can't help you out!");
  }

  unless (grep {; $_ eq $user->username } $self->board_admins) {
    return $event->error_reply("Sorry, only board admins can grant tokens");
  }

  my ($who, $count) = $event->text =~ /^vesta grant\s+(\S+)\s+([0-9]+)\s+tokens/;

  unless ($who && length $count) {
    return $event->error_reply(q{Hmm, I don't understand: use "vesta grant WHO COUNT tokens"});
  }

  my $target = $self->resolve_name($who, $event->from_user);

  unless ($target) {
    return $event->error_reply("Sorry, I don't know who $who is.");
  }

  $count = 10 if $count > 10;  # this isn't Nam, Walter.

  my $state = $self->_user_state->{ $target->username } //= {};
  my $token_state = $state->{tokens} //= {};

  $token_state->{count} += $count;
  $self->save_state;

  return $event->reply(sprintf("Ok! I've given %s %s %s.",
    $target->username, $count, PL_N('token', $count)
  ));
}

sub handle_vesta_designs ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I can't help you out!");
  }

  my $state = $self->_user_state->{ $user->username } //= {};

  unless ($state->{designs} && keys $state->{designs}->%*) {
    return $event->reply("You don't have any Vestaboard designs on file.");
  }

  my $text = "Here are your designs on file:\n";
  $text .= "• $_->{name}\n" for values $state->{designs}->%*;

  return $event->reply($text);
}

sub handle_vesta_delete_design ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I can't help you out!");
  }

  my ($name) = $event->text =~ /\Avesta delete design\s+(.+)/;

  $name =~ s/[^\pL\pN\pM]/-/g;
  $name =~ s/-{2,}/-/g;

  my $name_key = NFD(fc $name);

  my $state = $self->_user_state->{ $user->username } //= {};

  unless (exists $state->{designs}{ $name_key }) {
    return $event->reply("You don't have a design with that name.");
  }

  delete $state->{designs}{$name_key};

  $self->save_state;

  return $event->reply("Okay, I've deleted that design.");
}

sub handle_vesta_status ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  my $status;

  if (my $lock = $self->current_lock) {
    my $time_left = $lock->{expires_at} - time;

    $status = sprintf 'The board is locked by %s until %s.',
      $lock->{locked_by},
      ($time_left > 86_400*7
        ? 'some far-off time'
        : $user->format_timestamp($lock->{expires_at}));
  } else {
    $status = "The board is unlocked.";
  }

  my $tokens = $self->_updated_tokens_for($user);

  $status .= sprintf "  You have %s board %s.",
    scalar($tokens == 0 ? 'no' : NUMWORDS($tokens)),
    PL_N('token', $tokens);

  if ($tokens < $self->max_token_count) {
    my $state = $self->_user_state->{ $user->username };
    my $next = $state->{tokens}{next};
    $status .= sprintf "  You'll get another token in %s.",
      duration($next - time);
  }

  $event->reply($status);
}

sub handle_vesta_edit ($self, $event) {
  $event->mark_handled;

  my $text = $event->text;
  my $name = $text =~ s/\Avesta edit\s+//r;
  $name =~ s/[^\pL\pN\pM]/-/g;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  if ($event->is_public) {
    $event->reply("I'll send you a link to edit the Vestaboard in private.");
  }

  my $secret = $self->_secret_for($user);
  my $uri    = URI->new($self->editor_uri);
  $uri->query_param(design   => $name);
  $uri->query_param(username => $user->username);
  $uri->query_param(secret => $secret);

  if (my $design = $self->_get_user_design_named($user, $name)) {
    # A design exists, so let's try to encode it.
    my $state = eval {
      Synergy::VestaUtil->encode_board($design->{characters});
    };

    if ($state) {
      $uri->query_param(state => $state);
    } else {
      $Logger->log("error producing state string: $@");
    }
  }

  $Logger->log("sending user $uri");

  $event->private_reply(
    "Okay, time to get editing! Click here: $uri",
    {
      slack => sprintf(
        "Okay, head over to <%s|the Vestaboard editor>!",
        "$uri",
      ),
    },
  );
}

sub _validate_secret_for ($self, $user, $secret) {
  my $hashref = $self->_user_state->{ $user->username };

  $Logger->log_debug([
    'u=<%s> secret=<%s> state=<%s>',
    $user->username,
    $secret,
    $hashref,
  ]);

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

sub _get_user_design_named ($self, $user, $name) {
  my $name_key = NFD(fc $name);

  my $this_user_state = $self->_user_state->{ $user->username } //= {};
  my $design = $this_user_state->{designs}{$name_key};

  return $design;
}

sub handle_vesta_post ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  my ($name) = $event->text =~ /\Avesta post\s+(\S+)\z/i;
  my $design = $self->_get_user_design_named($user, $name);

  unless ($design) {
    return $event->error_reply("Sorry, I couldn't find a design with that name.");
  }

  $self->_pay_to_post_payload(
    $event,
    $user,
    {
      characters => $design->{characters},
    }
  );
}

sub handle_vesta_post_text ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  my ($text) = $event->text =~ /\Avesta post text:? (.+)\z/i;

  my ($board, $error) = Synergy::VestaUtil->text_to_board($text);

  unless ($board) {
    $error //= "Something went wrong.";
    return $event->error_reply("Sorry, I can't post that to the board.  $error");
  }

  $self->_pay_to_post_payload(
    $event,
    $user,
    {
      characters => $board,
    }
  );
}

sub handle_vesta_random_colors ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("I don't know who you are, so I'm not going to do that.");
  }

  # color codes for black + 7 blocks
  my @colors = (0, 63..69);

  my $len = 22 * 6;   # board size

  my @board;
  for my $line (1..6) {
    my @s = map {; $colors[int(rand(@colors))] } (1..22);
    push @board, \@s;
  }

  $self->_pay_to_post_payload(
    $event,
    $user,
    {
      characters => \@board,
    }
  );
}

sub _post_payload ($self, $payload) {
  if ($self->is_simulation) {
    return Future->done( HTTP::Response->new(200 => 'OK') );
  }

  my $uri = sprintf 'https://platform.vestaboard.com/subscriptions/%s/message',
    $self->subscription_id;

  return $self->hub->http_post(
    $uri,
    Content => JSON::MaybeXS->new->encode($payload),
    Content_Type => 'application/json',

    'X-Vestaboard-Api-Key'    => $self->api_key,
    'X-Vestaboard-Api-Secret' => $self->api_secret,
    'User-Agent'  => __PACKAGE__,
  );
}

sub _pay_to_post_payload ($self, $event, $user, $payload) {
  my $lock = $self->current_lock;
  if ($lock && $lock->{locked_by} ne $user->username) {
    $event->error_reply("Sorry, the board can't be changed right now!");
    return;
  }

  my $tokens = $self->_updated_tokens_for($user);

  unless ($tokens > 0) {
    $event->error_reply("Sorry, you don't have any tokens!");
    return;
  }

  my $res_f = $self->_post_payload($payload);

  return $res_f
    ->then(sub ($res) {
      $Logger->log([
        "posted update to Vestaboard API, status: %s",
        $res->status_line,
      ]);
      $event->reply("Board update posted!");

      my $state = $self->_user_state->{ $user->username } //= {};
      $state->{tokens}{count} = $tokens - 1;

      $self->_set_lock_state({
        locked_by   => $user->username,
        expires_at  => int(time + ($self->token_regen_period / 2)),
      });

      if ($payload->{characters}) {
        # We might have "text" which we'll ignore for now.  Later, we can make
        # the text-posting command build characters locally instead of using
        # the text-posting Vestaboard API. -- rjbs, 2021-09-04
        $self->_set_current_characters($payload->{characters});
      }

      $self->save_state;
      return Future->done;
    })
    ->else(sub {
      $event->reply_error("Sorry, something went wrong trying to post!");
    })->retain;
}

sub _updated_tokens_for ($self, $user) {
  my $state = $self->_user_state->{ $user->username } //= {};
  my $token_state = $state->{tokens} //= {};

  $token_state->{next}  //= time - 1;
  $token_state->{count} //= 0;
  $token_state->{count}   = 0 if $token_state->{count} < 0;

  if ($token_state->{count} < $self->max_token_count && time > $token_state->{next}) {
    $token_state->{count}++;
    $token_state->{next} = time + $self->token_regen_period;
    $self->save_state;
  }

  return $token_state->{count};
}

1;
