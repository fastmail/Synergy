use v5.32.0;
use warnings;
package Synergy::Reactor::Yelling;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(isa signatures);
use namespace::clean;

use Future::AsyncAwait;

use Synergy::CommandPost;
use URI;

has slack_synergy_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has yelling_channel_name => (
  is => 'ro',
  isa => 'Str',
  default => 'yelling',
);

sub _slack_channel_name_from_event ($self, $event) {
  my $channel_id = $event->conversation_address;
  my $channel = $event->from_channel->slack->channels->{$channel_id}{name};

  return $channel // '';
}

async sub start ($self) {
  my $slack_channel = $self->hub->channel_named( $self->slack_synergy_channel_name );

  $slack_channel->register_pre_message_hook(sub ($event, $text_ref, $alts) {
    my $chan = $self->_slack_channel_name_from_event($event);
    return unless $chan eq $self->yelling_channel_name;

    $$text_ref = uc $$text_ref;

    # We skip doing this rewrite if the slack alt text is a reference, which is
    # what happens when it's using BlockKit.  Later, we could run a visitor
    # across the structure and only affect the "text" properties.
    # -- rjbs, 2024-03-21
    if (exists $alts->{slack} && defined $alts->{slack} && ! ref $alts->{slack}) {
      my @hunks = split /(<[^>]+?>)/, $alts->{slack};
      $alts->{slack} = join '', map {; /^</ ? $_ : uc } @hunks;
    }
  });

  return;
}

responder mumbling => {
  matcher => sub ($self, $text, $event) {
    return unless $event->from_channel isa Synergy::Channel::Slack;

    my $channel = $self->_slack_channel_name_from_event($event);
    return unless $channel eq $self->yelling_channel_name;

    my @words = split /\s+/, $event->text;
    for (@words) {
      next if m/^[#@]/; # don't complain about @rjbs

      # or :smile: or :-1::skin-tone-4:
      next if m/^:[+-_a-z0-9]+(?::skin-tone-[2-6]:)?:$/;

      next if URI->new($_)->has_recognized_scheme;  # or URLS

      # do complain about lowercase
      return [] if m/\p{Ll}/;
    }

    return;
  },
} => async sub ($self, $event) {
  return await $event->reply("YOU'RE MUMBLING.");
};

1;
