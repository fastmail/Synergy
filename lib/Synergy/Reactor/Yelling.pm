use v5.24.0;
use warnings;
package Synergy::Reactor::Yelling;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

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

sub start ($self) {
  my $slack_channel = $self->hub->channel_named( $self->slack_synergy_channel_name );

  $slack_channel->register_pre_message_hook(sub ($event, $text_ref, $alts) {
    my $chan = $self->_slack_channel_name_from_event($event);
    return unless $chan eq $self->yelling_channel_name;

    $$text_ref = uc $$text_ref;

    if (exists $alts->{slack} && defined $alts->{slack}) {
      my @hunks = split /(<[^>]+?>)/, $alts->{slack};
      $alts->{slack} = join '', map {; /^</ ? $_ : uc } @hunks;
    }
  });
}

sub listener_specs {
  return {
    name      => 'yell_more',
    method    => 'handle_mumbling',
    exclusive => 0,
    predicate => sub ($self, $e) {
      return unless $e->from_channel->isa('Synergy::Channel::Slack');

      my $r = $self->reactor;
      my $channel = $r->_slack_channel_name_from_event($e);
      return unless $channel eq $r->yelling_channel_name;

      my $text = $e->text;
      $text =~ s/[#@](?:\S+)//g;  # don't complain about @rjbs
      $text =~ s/:[-_a-z0-9]+://g; # don't complain about :smile:

      return $text =~ /\p{Ll}/;
    },
  };
}

sub handle_mumbling ($self, $event) {
  $event->reply("YOU'RE MUMBLING.");
}

1;
