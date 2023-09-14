use v5.32.0;
use warnings;
package Synergy::Reactor::DiscordDiagnostics;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use List::Util qw(first);
use Synergy::CommandPost;
use YAML::XS ();

command 'dd-message' => {
} => async sub ($self, $event, $rest) {
  unless ($event->from_channel->isa('Synergy::Channel::Discord')) {
    return await $event->error_reply("Sorry, you can't use *dd-message* outside Discord");
  }

  my $dump = YAML::XS::Dump($event->transport_data);
  my $text = "```yaml\n$dump\n```";

  return await $event->reply($text);
};

1;
