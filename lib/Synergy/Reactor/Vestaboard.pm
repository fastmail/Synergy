use v5.24.0;
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

has secret_url_component => (
  is => 'ro',
);

sub listener_specs {
  return (
    {
      name      => 'vesta_edit',
      method    => 'handle_vesta_edit',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && lc $e->text =~ /\Avesta edit /i;
      },
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
      predicate => sub ($, $e) {
        $e->was_targeted && lc $e->text =~ /\Avesta delete design /;
      },
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
      predicate => sub ($, $e) {
        $e->was_targeted && lc $e->text eq 'vesta designs';
      },
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
      predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /\Avesta post text:? .+\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta post text `TEXT`*: post a text message to the board",
        }
      ],
    },
    {
      name      => 'vesta_post',
      method    => 'handle_vesta_post',
      exclusive => 1,
      predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /\Avesta post \S+\z/i },
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
      predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /\Avesta status\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta status*: check the board status and your token count",
        }
      ],
    },
    {
      name      => 'vesta_show',
      method    => 'handle_vesta_show',
      exclusive => 1,
      predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /\Avesta show\z/i },
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
      predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /\Avesta (un)?lock\z/i },
      help_entries => [
        {
          title => 'vesta',
          text  => "*vesta lock/unlock*: (admins only) lock or unlock the board",
        }
      ],
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
    return '/vesta/' . $self->name . '/';
  },
);

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

  if ($req->method eq 'POST') {
    my $payload  = eval { JSON::MaybeXS->new->decode($req->content); };

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
  } else {
    $Logger->log("Serving raw editor");

    open my $fh, '<', join(q{/}, $self->asset_directory, 'index.html');
    return [
      200,
      [ "Content-Type" => "text/html; charset=utf-8" ],
      $fh,
    ];
  }
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

  $self->_setup_asset_servers;

  $self->_setup_content_server if $self->secret_url_component;

  return;
};

sub _setup_asset_servers ($self) {
  # I know, this is incredibly stupid, but it gets the job done.  We can talk
  # about better ways to do this at some future date. -- rjbs, 2021-05-31

  my $root = $self->asset_directory;
  my @files = `find $root -type f`;
  chomp @files;

  my $server = $self->hub->server;
  my $base   = $self->http_path;

  for my $path (@files) {
    my $mount_as = $path =~ s{\A$root/}{}r;

    $server->register_path("$base$mount_as", sub ($env) {
      open my $fh, '<', $path or die "can't read asset file $path: $!";

      return [
        200,
        [
          'Content-Type', Plack::MIME->mime_type($path),
        ],
        $fh,
      ];
    });
  }

  return;
}

sub _setup_content_server ($self) {
  my $secret = $self->secret_url_component;

  my $base = $self->http_path;
  $base =~ s{/\z}{};
  my $path = "${base}/$secret";

  $self->hub->server->register_path($path, sub ($env) {
    return [
      200,
      [
        'Content-Type', 'application/json',
      ],
      [ JSON::MaybeXS->new->encode($self->_current_characters) ],
    ];
  });

  return;
}

my %CHAR_FOR = (
  0 => "\N{IDEOGRAPHIC SPACE}",
  (map { $_ => chr(0xFF20 + $_) }      ( 1 .. 26)), # A .. Z
  (map { $_ => chr(0xFF10 + $_ - 26) } (27 .. 35)), # 1 .. 9
  36 => "\x{FF10}", # Zero

  40 => "\N{FULLWIDTH DOLLAR SIGN}",
  41 => "\N{FULLWIDTH LEFT PARENTHESIS}", # '(',
  42 => "\N{FULLWIDTH RIGHT PARENTHESIS}", # ')',

  44 => "\N{FULLWIDTH HYPHEN-MINUS}", # '-',

  46 => "\N{FULLWIDTH PLUS SIGN}", # '+',
  47 => "\N{FULLWIDTH AMPERSAND}", # '&',
  48 => "\N{FULLWIDTH EQUALS SIGN}", # '=',
  49 => "\N{FULLWIDTH SEMICOLON}", # ';',
  37 => "\N{FULLWIDTH EXCLAMATION MARK}", # '!',
  38 => "\N{FULLWIDTH COMMERCIAL AT}", # '@',
  39 => "\N{FULLWIDTH NUMBER SIGN}", # '#',
  50 => "\N{FULLWIDTH COLON}", # ':',

  52 => "\N{FULLWIDTH APOSTROPHE}", # "'",
  53 => "\N{FULLWIDTH QUOTATION MARK}",
  54 => "\N{FULLWIDTH PERCENT SIGN}",
  55 => "\N{FULLWIDTH COMMA}",
  56 => "\N{FULLWIDTH FULL STOP}",

  59 => "\N{FULLWIDTH SOLIDUS}",
  60 => "\N{FULLWIDTH QUOTATION MARK}",
  62 => "° ", # no full-width variant available
  63 => '🟥', # here and below: the colors
  64 => '🟧',
  65 => '🟨',
  66 => '🟩',
  67 => '🟦',
  68 => '🟪',
  69 => '⬜️',
);

my %CODE_FOR = (
  ' ' => 0,
  (map {; $_ => ord($_) - 0x40 } ('A' .. 'Z')),
  '0' => 36,
  (map {; $_ => ord($_) - 0x29 } ( 1 ..   9 )),

  # If put into the qw[...], we'll get a warning, and this is simpler than
  # faffing about with "no warnings". -- rjbs, 2021-09-05
  '#' => 39,
  ',' => 55,

  qw[
      !   37
      @   38
      $   40
      (   41
      )   42
      -   44
      +   46
      &   47
      =   48
      ;   49
      :   50
      '   52
      "   53
      %   54
      .   56
      /   59
      ?   60
      °   62
  ],
);

sub _characters_to_display_text ($self, $characters) {
  my @lines;
  for my $line (@$characters) {
    push @lines,
      join q{}, map {; $CHAR_FOR{$_} // "\N{IDEOGRAPHIC SPACE}" } @$line;
  }

  return join qq{\n}, @lines;
}

sub handle_vesta_show ($self, $event) {
  $event->mark_handled;

  my $curr = $self->_current_characters;

  unless ($curr) {
    $event->reply("Sorry, I don't know what's on the board!");
    return;
  }

  my $display = $self->_characters_to_display_text($curr);
  my $reply   = "Currently on the board:\n$display";

  my $whitespace = $CHAR_FOR{0};

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
    $event->error_reply("I don't know who you are, so I can't help you out!");
    return;
  }

  unless (grep {; $_ eq $user->username } $self->board_admins) {
    $event->error_reply("Sorry, only board admins can lock or unlock the board");
    return;
  }

  if ($event->text =~ /vesta unlock/i) {
    $self->_set_lock_state({});
    $self->save_state;
    $event->reply("The board is now unlocked!");
    return
  }

  $self->_set_lock_state({
    locked_by   => $user->username,
    expires_at  => time + 2*86_400, # two days is probably a good default?
  });

  $self->save_state;

  $event->reply("The board is locked!  Don't forget to unlock it later.");
  return
}

sub handle_vesta_designs ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    $event->error_reply("I don't know who you are, so I can't help you out!");
    return;
  }

  my $state = $self->_user_state->{ $user->username } //= {};

  unless ($state->{designs} && keys $state->{designs}->%*) {
    $event->reply("You don't have any Vestaboard designs on file.");
    return;
  }

  my $text = "Here are your designs on file:\n";
  $text .= "• $_->{name}\n" for values $state->{designs}->%*;

  $event->reply($text);
  return;
}

sub handle_vesta_delete_design ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    $event->error_reply("I don't know who you are, so I can't help you out!");
    return;
  }

  my ($name) = $event->text =~ /\Avesta delete design\s+(.+)/;

  $name =~ s/[^\pL\pN\pM]/-/g;
  $name =~ s/-{2,}/-/g;

  my $name_key = NFD(fc $name);

  my $state = $self->_user_state->{ $user->username } //= {};

  unless (exists $state->{designs}{ $name_key }) {
    $event->reply("You don't have a design with that name.");
    return;
  }

  delete $state->{designs}{$name_key};

  $self->save_state;

  $event->reply("Okay, I've deleted that design.");
  return;
}

sub handle_vesta_status ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
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

sub _encode_board {
  my ($self, $board) = @_;
  my $str = q{};
  my @queue = map {; @$_ } @$board;

  QUAD: while (defined(my $code = shift @queue)) {
    if (@queue >= 2 && $queue[0] == $code && $queue[1] == $code) {
      my $n = 3;
      splice @queue, 0, 2;

      while (@queue && $queue[0] == $code) {
        $n++;
        shift @queue;
      }

      $str .= chr($code | 128) . chr($n);

      next QUAD;
    }

    $str .= chr($code);
  }

  return MIME::Base64::encode_base64url($str);
}

sub handle_vesta_edit ($self, $event) {
  $event->mark_handled;

  my $text = $event->text;
  my $name = $text =~ s/\Avesta edit\s+//r;
  $name =~ s/[^\pL\pN\pM]/-/g;

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
  $uri->query_param(design   => $name);
  $uri->query_param(username => $user->username);
  $uri->query_param(secret => $secret);

  if (my $design = $self->_get_user_design_named($user, $name)) {
    # A design exists, so let's try to encode it.
    my $state = eval { $self->_encode_board($design->{characters}); };

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

  return;
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
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($name) = $event->text =~ /\Avesta post\s+(\S+)\z/i;
  my $design = $self->_get_user_design_named($user, $name);

  unless ($design) {
    $event->error_reply("Sorry, I couldn't find a design with that name.");
    return;
  }

  $self->_pay_to_post_payload(
    $event,
    $user,
    {
      characters => $design->{characters},
    }
  );
}

sub _text_to_characters ($self, $text) {
  # This will return either [...characters...] or a string that indicates what
  # went wrong.  This is stupid, but it's ... fine? -- rjbs, 2021-09-05
  $text = uc $text;

  $text =~ s/[‘’]/'/g; # Slack likes to smarten up quotes,
  $text =~ s/[“”]/"/g; # which is stupid. -- rjbs, 2021-08-12

  my @words = grep {; length } split /\s+/, $text;

  unless (@words) {
    return "There wasn't anything to post!";
  }

  my %unknown;
  for (@words) {
    $_ = [ map {; $CODE_FOR{$_} // ($unknown{$_} = -1) } split //, $_ ];
  }

  if (%unknown) {
    my @chars = sort keys %unknown;
    return "I didn't know what to do with these: @chars";
  }

  my @lines = ([]);
  while (defined(my $word = shift @words)) {
    if ($lines[-1]->@* + @$word + 1 < 22) {
      push $lines[-1]->@*, ($lines[-1]->@* ? 0 : ()), @$word;
    } elsif (@lines == 6) {
      return "I can't make the text fit.";
    } else {
      push @lines, [ @$word ];
    }
  }

  # 1. for given lines, left and right pad
  my ($minpad) = 22 - (sort { $b <=> $a } map {; 0 + @$_ } @lines)[0];
  my $leftpad  = int($minpad / 2) + ($minpad % 2);
  unshift @$_, (0) x $leftpad for @lines;
  push @$_, (0) x (22 - @$_) for @lines;

  # 2. add blank lines at top and bottom
  my $addlines = 6 - @lines;
  my $front    = int($addlines / 2) + ($addlines % 2);

  @lines = (
    (map {; [ (0) x 22 ] } (1 .. $front)),
    @lines,
    (map {; [ (0) x 22 ] } (1 .. $addlines - $front))
  );

  return \@lines;
}

sub handle_vesta_post_text ($self, $event) {
  $event->mark_handled;

  my $user = $event->from_user;

  unless ($user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($text) = $event->text =~ /\Avesta post text:? (.+)\z/i;

  $text = uc $text;

  $text =~ s/[‘’]/'/g; # Slack likes to smarten up quotes,
  $text =~ s/[“”]/"/g; # which is stupid. -- rjbs, 2021-08-12

  unless ($self->_text_is_valid($text)) {
    $event->error_reply("Sorry, I can't post that to the board.");
    return;
  }

  my $post = $self->_text_to_characters($text);

  unless (ref $post) {
    $event->error_reply("Sorry, I can't post that to the board.  $post");
    return;
  }

  $self->_pay_to_post_payload(
    $event,
    $user,
    {
      characters => $post,
    }
  );
}

sub _text_is_valid ($self, $text) {
  # This feels pretty thing. -- rjbs, 2021-05-31
  return if $text =~ m{[^ 0-9A-Z!@#\$\(\)-\+&=;:'"%,./?°]};
  return if length $text > 6 * 22;
  return 1;
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

  my $uri = sprintf 'https://platform.vestaboard.com/subscriptions/%s/message',
    $self->subscription_id;

  my $res_f = $self->hub->http_post(
    $uri,
    Content => JSON::MaybeXS->new->encode($payload),
    Content_Type => 'application/json',

    'X-Vestaboard-Api-Key'    => $self->api_key,
    'X-Vestaboard-Api-Secret' => $self->api_secret,
    'User-Agent'  => __PACKAGE__,
  );

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

  $token_state->{count} //= 0;
  $token_state->{next}  //= time - 1;

  if ($token_state->{count} < $self->max_token_count && time > $token_state->{next}) {
    $token_state->{count}++;
    $token_state->{next} = time + $self->token_regen_period;
  }

  return $token_state->{count};
}

1;
