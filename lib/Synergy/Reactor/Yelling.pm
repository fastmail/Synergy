use v5.24.0;
use warnings;
package Synergy::Reactor::Yelling;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use Synergy::External::Slack;

sub listener_specs {
  return {
    name      => 'yell_more',
    method    => 'handle_mumbling',
    exclusive => 0,
    predicate => sub ($self, $e) {
      return unless $e->from_channel->isa('Synergy::Channel::Slack');

      my $channel_id = $e->conversation_address;
      my $channel = $e->from_channel->slack->channels->{$channel_id}{name};

      return unless $channel eq 'yelling';

      my $text = $e->text;
      $text =~ s/[#@](?:\S+)//g;  # don't complain about @rjbs
      $text =~ s/:[-_a-z0-9]+://g; # don't complain about :smile:

      return $text =~ /\p{Ll}/;
    },
  };
}

sub handle_mumbling ($self, $event) {
  $self->muck_around_with_event_mop($event);
  $event->reply("YOU'RE MUMBLING.");
}

# What's this, you ask? GREAT QUESTION.
# If this is #yelling, we will munge the reply method on _this_ event's
# meta-object, such that it uppercases anything sent to it. We also need to
# munge the prefix getter so that the prefix gets uppercased too.
# -- michael, 2019-02-18
sub muck_around_with_event_mop ($self, $event) {
  my $meta = $event->meta;
  my $reply_method = $meta->find_method_by_name('reply');
  my $prefix_method = $meta->find_method_by_name('get_reply_prefix');

  my $orig_reply = $reply_method->body;
  my $orig_prefix = $prefix_method->body;

  $reply_method->{body} = sub {
    my ($self, $text, $alts, $args) = @_;
    $alts //= {};
    $args //= {};

    if (exists $alts->{slack} && defined $alts->{slack}) {
      $alts->{slack} = uc $alts->{slack};
    }

    $text = uc $text;
    $orig_reply->($self, $text, $alts, $args);
  };

  $prefix_method->{body} = sub {
    my ($self) = @_;
    return uc $orig_prefix->($self);
  };

  $meta->remove_method('reply');
  $meta->add_method(reply => $reply_method);

  $meta->remove_method('get_reply_prefix');
  $meta->add_method(get_reply_prefix => $prefix_method);
}

1;
