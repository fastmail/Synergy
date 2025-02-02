use v5.36.0;
package Synergy::Reactor::DiscordDiagnostics;

use utf8;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use JSON::MaybeXS ();
use List::Util qw(first);
use Synergy::Logger '$Logger';
use YAML::XS ();

use Synergy::CommandPost;

command 'dd-message' => {
} => async sub ($self, $event, $rest) {
  unless ($event->from_channel->isa('Synergy::Channel::Discord')) {
    return await $event->error_reply("Sorry, you can't use *dd-message* outside Discord");
  }

  $YAML::XS::Boolean = 'JSON::PP';
  my $dump = YAML::XS::Dump($event->transport_data);
  my $text = "```yaml\n$dump\n```";

  return await $event->reply($text);
};

command 'dd-guild' => {
} => async sub ($self, $event, $rest) {
  unless ($event->from_channel->isa('Synergy::Channel::Discord')) {
    return await $event->error_reply("Sorry, you can't use *dd-guild* outside Discord");
  }

  my $guild_id  = $event->transport_data->{guild_id};
  $Logger->log("guild is $guild_id");

  my $guild_res = await $event->from_channel->discord->api_get("/guilds/$guild_id");
  my $guild     = JSON::MaybeXS->new->decode(
    $guild_res->decoded_content(charset => undef)
  );

  $guild->{emojis} = '...elided...';
  $guild->{roles}  = '...elided...';

  $YAML::XS::Boolean = 'JSON::PP';
  my $dump = YAML::XS::Dump($guild);
  my $text = "```yaml\n$dump\n```";

  return await $event->reply($text);
};

command 'dd-channel' => {
} => async sub ($self, $event, $rest) {
  unless ($event->from_channel->isa('Synergy::Channel::Discord')) {
    return await $event->error_reply("Sorry, you can't use *dd-guild* outside Discord");
  }

  my $channel_id = $event->transport_data->{channel_id};

  unless ($channel_id) {
    return await $event->reply("This message wasn't in a channel.");
  }

  my $channel = $event->from_channel->discord->get_channel($channel_id);

  unless ($channel_id) {
    return await $event->reply("I have no information about this channel! 🤔");
  }

  $YAML::XS::Boolean = 'JSON::PP';
  my $dump = YAML::XS::Dump($channel);
  my $text = "```yaml\n$dump\n```";

  return await $event->reply($text);
};

command 'dd-comps' => {
} => async sub ($self, $event, $rest) {
  return await $event->reply(
    "This text will never be seen.",
    {
      discord => {
        content => "This message is a test of components.",
        components => [
          {
            type => 1,
            components => [
              {
                type => 2,
                label => "Click me!",
                style => 1,
                custom_id => "click_one"
              }
            ]
          }
        ],
      }
    }
  );
};

1;
