use v5.24.0;
package Synergy::Reactor::CatPic;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use Synergy::Logger '$Logger';

use experimental qw(signatures);
use namespace::clean;

my %PIC_FOR;

sub register_pic {
  my ($emoji, $name, $slackname) = split /\s+/, $_[0];
  my $e = $PIC_FOR{$name} ||= { emoji => q{}, slacknames => {} };

  $e->{emoji} .= $emoji;
  $e->{slacknames}{$slackname // $name} = 1;
  return;
}

my $EMOJI_CONFIG = <<'END_EMOJI';
🐀 rat
🐭 mouse
🐁 mouse          mouse2
🐂 ox
🐃 water_buffalo
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
🐝 bee
🐞 ladybug
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
🦒 giraffe
🦔 hedgehog
🦕 sauropod
🦖 trex           t-rex
🦖 t-rex          t-rex
🦗 cricket
🦕 dinosaur       sauropod
🦖 dinosaur       t-rex
END_EMOJI

register_pic($_) for split /\n/, $EMOJI_CONFIG;

sub listener_specs {
  return (
    {
      name      => 'misc-pic',
      method    => 'handle_misc_pic',
      predicate => sub ($self, $e) {
        $e->text =~ /(\w+)\s+pic/ && $PIC_FOR{$1}
      },
    },
    {
      name      => 'dog-pic',
      method    => 'handle_dog_pic',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Adog\s+pic\z/
      },
    },
    {
      name      => 'cat-pic',
      method    => 'handle_cat_pic',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Acat\s+(pic|jpg|gif|png)\z/
      },
    },
  );
}

sub handle_cat_pic ($self, $event, $rch) {
  $event->mark_handled;

  my (undef, $fmt) = split /\s+/, $event->text, 2;
  $fmt = q{jpg,gif,png} if $fmt eq 'pic';

  my $res = $self->hub->http->GET(
    "http://thecatapi.com/api/images/get?format=src&type=$fmt",
    max_redirects => 0,
  )->get;

  if ($res->code =~ /\A3..\z/) {
    my $loc = $res->header('Location');
    $rch->reply($loc);
    return;
  }

  $rch->reply("Something went wrong getting the kitties! \N{CRYING CAT FACE}");
  return;
}

sub handle_misc_pic ($self, $event, $rch) {
  my $text = $event->text;
  while ($text =~ /(\w+)\s+pic/g) {
    my $name = $1;
    $Logger->log("looking for $1 pic");
    next unless my $e = $PIC_FOR{$name};

    # If this is all they said, okay.
    $event->mark_handled if $text =~ /\A \s* $1 \s+ pic \s* \z/x;

    my $emoji = substr $e->{emoji}, (int rand length $e->{emoji}), 1;

    my @slack_names = keys $e->{slacknames}->%*;
    my $slack = @slack_names[ int rand @slack_names ];

    # Weak. -- rjbs, 2018-06-16
    return unless $rch->channel->isa('Synergy::Channel::Slack');

    $rch->reply(
      "$emoji",
      {
        slack_reaction => { event => $event, reaction => $slack },
      },
    );
  }

  return;
}

sub handle_dog_pic ($self, $event, $rch) {
  $event->mark_handled;

  my $res = $self->hub->http_get(
    "https://dog.ceo/api/breeds/image/random",
  );

  my $json = eval { JSON::MaybeXS->new->decode( $res->decoded_content ) };
  my $error = $@;

  if ($json && $json->{status} eq 'success') {
    $rch->reply($json->{message});
    return;
  }

  $Logger->log("doggo error: $error") if $error;
  $rch->reply("Something went wrong getting the doggos!");
  return;
}

1;
