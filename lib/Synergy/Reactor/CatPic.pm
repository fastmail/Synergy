use v5.32.0;
use warnings;
package Synergy::Reactor::CatPic;

use utf8;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use Future::AsyncAwait;
use Synergy::CommandPost;

use Synergy::Logger '$Logger';

use experimental qw(isa lexical_subs signatures);

my $EMOJI_CONFIG = <<'END_EMOJI';
🐀 rat
🐭 mouse
🐁 mouse          mouse2
🐂 ox
🐃 water_buffalo
🐃 buffalo        water_buffalo
🐄 cow            cow2
🐮 cow
🐅 tiger          tiger2
🐯 tiger
🐆 leopard
🐇 rabbit         rabbit2
🐰 rabbit
🐈 cat            cat2
🐱 cat
🐉 dragon
🐲 dragon         dragon_face
🐊 crocodile
🐋 whale          whale2
🐳 whale
🐌 snail
🐍 snake
🐎 horse          racehorse
🐴 horse
🐏 ram
🐐 goat
🐑 sheep
🐒 monkey
🐵 monkey         monkey_face
🙈 monkey         see_no_evil
🙉 monkey         hear_no_evil
🙊 monkey         speak_no_evil
🐓 rooster
🐔 chicken
🥚 chicken        egg
🐶 dog
🐕 dog            dog2
🐖 pig            pig2
🥓 pig            bacon
🐗 boar
🐘 elephant
🐙 octopus
🐛 bug
🐜 ant
🦗 cricket
🕷 spider
🐝 bee
🐞 ladybug        beetle
🐟 fish
🐠 fish           tropical_fish
🐡 fish           blowfish
🐡 blowfish
🐢 turtle
🐣 chick          hatching_chick
🐤 chick          baby_chick
🐥 chick          hatched_cick
🐦 bird
🐧 penguin
🐨 koala
🐩 poodle
🐩 dog            poodle
🐪 camel          dromedary_camel
🐫 camel
🐫 perl           camel
🐬 dolphin
🐷 pig
🐸 frog
🐹 hamster
🐺 wolf
🐻 bear
🐼 panda
🐿 chipmunk
🦀 crab
🦁 lion
🦂 scorpion
🦃 turkey
🦄 unicorn
🦅 eagle
🦆 duck
🦇 bat
🦈 shark
🦉 owl
🦊 fox            fox_face
🦋 butterfly
🦌 deer
🦍 gorilla
🦎 lizard
🦏 rhinoceros
🦐 shrimp
🦑 squid
🦓 zebra
🦒 giraffe        giraffe_face
🦔 hedgehog
🦕 sauropod
🦖 trex           t-rex
🦖 t-rex          t-rex
🦗 cricket
🦕 dinosaur       sauropod
🦖 dinosaur       t-rex

🕊 dove

🦝  raccoon
🦙  llama
🦛  hippo          hippopotamus
🦛  hippopotamus
🦘  kangaroo
🦘  roo            kangaroo
🦡  badger
🦢  swan
🦚  peacock
🦜  parrot
🦞  lobster
🦟  mosquito
🦟  skeeter        mosquito
🧸  teddy
🦠  microbe

🦮  guide_dog
🦥  sloth
🦦  otter
🦨  skunk
🦩  flamingo

🦬  bison
🦣  mammoth
🦫  beaver
🦤  dodo
🦭  seal
🪲  beetle
🪳  cockroach
🪰  fly
🪱  worm

🪸  coral

🫏  donkey
🫎  moose
🪿  goose
🪼  jellyfish
END_EMOJI

has _reactions => (
  is    => 'ro',
  isa   => 'HashRef',
  lazy  => 1,
  traits  => [ 'Hash' ],
  builder => '_build_reactions',
  handles => {
    reaction_for     => 'get',
    has_reaction_for => 'exists',
  },
);

my sub register_pic_line ($registry, $line) {
  my ($name, %to_set);

  ($to_set{emoji}, $name, $to_set{slackname}) = split /\s+/, $line;
  $to_set{slackname} //= $name;

  my $e = $registry->{$name} ||= { emoji => [], slackname => [] };

  for my $type (qw( emoji slackname )) {
    push $e->{$type}->@*, $to_set{$type}
      unless grep {; $_ eq $to_set{$type} } $e->{$type}->@*;
  }

  return;
}

sub _built_in_reactions {
  state %reactions;
  return {%reactions} if %reactions;

  register_pic_line(\%reactions, $_) for split /\n+/, $EMOJI_CONFIG;

  return {%reactions};
}

has extra_reactions_file => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_extra_reactions_file',
);

sub _build_reactions ($self, @) {
  my $reactions = $self->_built_in_reactions;

  if ($self->has_extra_reactions_file) {
    my $file = $self->extra_reactions_file;
    open my $fh, '<', $file or confess("can't open $file for reading: $!");
    my $contents = do { local $/; <$fh> };
    close $fh;
    register_pic_line($reactions, $_) for split /\n+/, $contents;
  }

  return $reactions;
}

responder llama_pic => {
  exclusive => 1,
  targeted  => 1,
  help_titles => [ 'llama pic' ],
  help      => '*llama pic*: get a picture of a llama',
  matcher   => sub ($text, @) {
    return unless $text =~ /\Allama\spic\z/i;
    return [];
  },
}, sub ($self, $event) {
  $event->mark_handled;

  my $http_future = $self->hub->http_client->GET(
    "https://llama-as-a-service.vercel.app/llama_url"
  );

  return $http_future->on_done(sub($res)  {
    
    if ($res->code == 200)  {
      $event->reply($res->content);
      return;
    }
    
    $event->reply("Error while retrieving llama pictures!")
  
  });
};

responder llama_fax => {
  exclusive => 1,
  targeted  => 1,
  help_titles => [ 'llama fax' ],
  help      => '*llama fax*: get a fact about a llama',
  matcher   => sub ($text, @) {
    return unless $text =~ /\Allama\s(facts?|fax)\z/i;
    return [];
  },
}, sub ($self, $event) {
  $event->mark_handled;

  my $http_future = $self->hub->http_client->GET(
    "https://llama-as-a-service.vercel.app/llama_fax"
  );

  return $http_future->on_done(sub($res)  {
    
    if ($res->code == 200)  {
      $event->reply($res->content);
      return;
    }

    $event->reply("Error while retrieving llama fax!")
  
  });
};

responder cat_pic => {
  exclusive => 1,
  targeted  => 1,
  help_titles => [ 'cat pic' ],
  help      => '*cat pic*: get a picture of a cat',
  matcher   => sub ($self, $text, @) {
    # TODO: make this an error instead of a give-up?
    return unless $text =~ /\Acat(?:\s+(pic|jpg|gif|png))?\z/i;
    return [ $1 || 'jpg,gif,png' ];
  },
}, sub ($self, $event, $fmt) {
  $event->mark_handled;

  $fmt = q{jpg,gif,png} if $fmt eq 'pic';

  my $http_future = $self->hub->http_client->GET(
    "https://api.thecatapi.com/api/images/get?format=src&type=$fmt",
    max_redirects => 0,
  );

  return $http_future->on_done(sub ($res) {
    if ($res->code =~ /\A3..\z/) {
      my $loc = $res->header('Location');
      $event->reply($loc);
      return;
    }

    $event->reply("Something went wrong getting the kitties! \N{CRYING CAT FACE}");
  });
};

responder capybara_pic => {
  exclusive => 1,
  targeted  => 1,
  help_titles => [ 'capybara pic' ],
  help      => '*capybara pic*: get a picture of a capybara',
  matcher   => sub ($self, $text, @) {
    # TODO: make this an error instead of a give-up?
    return unless $text =~ /\Acapybara(?:\s+(pic|jpg|gif|png))?\z/i;
    return [];
  },
}, async sub ($self, $event) {
  $event->mark_handled;

  my $res = await $self->hub->http_client->GET(
    "https://api.capy.lol/v1/capybara?json=true",
    max_redirects => 0,
  );

  my $data = eval { JSON::MaybeXS->new->decode( $res->decoded_content ) };
  my $url  = $data->{data}{url};

  $event->reply($url);
};

listener misc_pic => async sub ($self, $event) {
  my $text = $event->text;
  my $from_channel = $event->from_channel;

  while ($text =~ /(\w+)\s+pic/ig) {
    my $name = lc $1;
    $Logger->log("looking for $name pic");
    next unless my $e = $self->reaction_for($name);

    my $exact = $text =~ /\A \s* $name \s+ pic \s* \z/x;

    # If this is all they said, okay.
    $event->mark_handled if $exact;

    my $emoji  = $e->{emoji}->[ int rand $e->{emoji}->@* ];
    my $slack  = $e->{slackname}->[ int rand $e->{slackname}->@* ];

    if ($from_channel isa Synergy::Channel::Slack
     || $from_channel isa Synergy::Channel::Discord
     || $from_channel isa Synergy::Channel::Console
    ) {
      return await $event->reply(
        "[ pretend you got this cute reaction: $emoji ]",
        {
          discord_reaction => { event => $event, reaction => $emoji },
          slack_reaction   => { event => $event, reaction => $slack },
        },
      );
    }

    # This is sort of a mess.  If someone addresses us from an unsupported
    # channel, we don't want to play dumb, but we don't want to give stupid
    # replies to SMS because they contained "cat pic" embedded in them.  So if
    # we're not Slack (and by this point we know we're not) and the message is
    # exactly a pic request, we'll give an emoji reply.
    return await $event->reply($emoji) if $exact;
  }

  return;
};

# Sometimes, respond in passing to a mention of "jazz" with a saxophone
# slackmoji. -- michael, 2019-02-06
listener jazz_pic => async sub ($self, $event) {
  return unless $event->text =~ /jazz/i;
  return unless $event->from_channel isa Synergy::Channel::Slack;
  return unless rand() < 0.1;

  return await $event->reply(
    "\N{SAXOPHONE}",
    {
      slack_reaction => { event => $event, reaction => 'saxophone' },
    },
  );

  return;
};

# TODO: we want a way to write some kind of custom prefix matching hybrid
# listener / command?
responder dog_pic => {
  exclusive => 1,
  targeted  => 1,
  help_titles => [ 'dog pic' ],
  help      => '*dog pic*: get a picture of a dog',
  matcher   => sub ($self, $text, @) {
    return unless $text =~ /\Adog\s+pic\z/i
               || $text =~ /\Aunleash\s+the\s+hounds\z/i;
    return [];
  },
} => async sub ($self, $event) {
  $event->mark_handled;

  my $res = await $self->hub->http_get(
    "https://dog.ceo/api/breeds/image/random",
  );

  my $json = eval { JSON::MaybeXS->new->decode( $res->decoded_content ) };
  my $error = $@;

  if ($json && $json->{status} eq 'success') {
    return await $event->reply($json->{message});
  }

  $Logger->log("doggo error: $error") if $error;
  return await $event->reply("Something went wrong getting the doggos!");
};

1;
