use v5.24.0;
use warnings;
package Synergy::Reactor::CatPic;

use utf8;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use Synergy::Logger '$Logger';

use experimental qw(lexical_subs signatures);
use namespace::clean;

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

sub listener_specs {
  my ($reactor) = @_;

  return (
    {
      name      => 'misc-pic',
      method    => 'handle_misc_pic',
      predicate => sub ($self, $e) {
        $e->text =~ /(\w+)\s+pic/i && $reactor->has_reaction_for(lc $1);
      },
    },
    {
      name      => 'dog-pic',
      method    => 'handle_dog_pic',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && ($e->text =~ /\Adog\s+pic\z/i ||
                             $e->text =~ /\Aunleash\s+the\s+hounds\z/i);
      },
    },
    {
      name      => 'cat-pic',
      method    => 'handle_cat_pic',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Acat\s+(pic|jpg|gif|png)\z/i
      },
    },
    {
      name      => 'jazz-pic',
      method    => 'handle_jazz_pic',
      predicate => sub ($self, $e) { $e->text =~ /jazz/i },
    },
    {
      name      => 'eyes-pic',
      method    => 'handle_eyes_pic',
      predicate => sub ($self, $e) { $e->text =~ /nicola/i },
    },
  );
}

sub handle_cat_pic ($self, $event) {
  $event->mark_handled;

  my (undef, $fmt) = split /\s+/, lc $event->text, 2;
  $fmt = q{jpg,gif,png} if $fmt eq 'pic';

  my $http_future = $self->hub->http_client->GET(
    "https://api.thecatapi.com/api/images/get?format=src&type=$fmt",
    max_redirects => 0,
  );

  $http_future->on_done(sub ($res) {
    if ($res->code =~ /\A3..\z/) {
      my $loc = $res->header('Location');
      $event->reply($loc);
      return;
    }

    $event->reply("Something went wrong getting the kitties! \N{CRYING CAT FACE}");
  });

  return;
}

sub handle_misc_pic ($self, $event) {
  my $text = $event->text;
  while ($text =~ /(\w+)\s+pic/ig) {
    my $name = lc $1;
    $Logger->log("looking for $name pic");
    next unless my $e = $self->reaction_for($name);

    my $exact = $text =~ /\A \s* $name \s+ pic \s* \z/x;

    # If this is all they said, okay.
    $event->mark_handled if $exact;

    my $emoji  = $e->{emoji}->[ int rand $e->{emoji}->@* ];
    my $slack  = $e->{slackname}->[ int rand $e->{slackname}->@* ];

    if ($event->from_channel->isa('Synergy::Channel::Slack')) {
      return $event->reply(
        $emoji,
        {
          slack_reaction => { event => $event, reaction => $slack },
        },
      );
    }

    if ($event->from_channel->isa('Synergy::Channel::Discord')) {
      $Logger->log("discord");
      return $event->reply(
        $emoji,
        {
          discord_reaction => { event => $event, reaction => $emoji },
        },
      );
    }

    # This is sort of a mess.  If someone addresses us from not-Slack, we don't
    # want to play dumb, but we don't want to give stupid replies to SMS
    # because they contained "cat pic" embedded in them.  So if we're not Slack
    # (and by this point we know we're not) and the message is exactly a pic
    # request, we'll give an emoji reply.
    $event->reply($emoji) if $exact;
    return;
  }

  return;
}

# Sometimes, respond in passing to a mention of "jazz" with a saxophone
# slackmoji. -- michael, 2019-02-06
sub handle_jazz_pic ($self, $event) {
  return unless $event->from_channel->isa('Synergy::Channel::Slack');
  return unless rand() < 0.1;

  return $event->reply(
    "\N{SAXOPHONE}",
    {
      slack_reaction => { event => $event, reaction => 'saxophone' },
    },
  );

  return;
}

# Sometimes, respond in passing to a mention of "nicola" with googly eyes
# slackmoji. -- brong, 2019-02-19
sub handle_eyes_pic ($self, $event) {
  return unless $event->from_channel->isa('Synergy::Channel::Slack');
  return unless rand() < 0.1;

  return $event->reply(
    "\N{EYES}",
    {
      slack_reaction => { event => $event, reaction => 'eyes' },
    },
  );

  return;
}

sub handle_dog_pic ($self, $event) {
  $event->mark_handled;

  my $http_future = $self->hub->http_get(
    "https://dog.ceo/api/breeds/image/random",
  );

  $http_future->on_done(sub ($res) {
    my $json = eval { JSON::MaybeXS->new->decode( $res->decoded_content ) };
    my $error = $@;

    if ($json && $json->{status} eq 'success') {
      $event->reply($json->{message});
      return;
    }

    $Logger->log("doggo error: $error") if $error;
    $event->reply("Something went wrong getting the doggos!");
  });

  return;
}

1;
