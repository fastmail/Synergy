use v5.32.0;
use warnings;
package Synergy::Reactor::Page;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use utf8;

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use List::Util qw(first);
use Synergy::CommandPost;
use Synergy::Util qw(bool_from_text);
use Synergy::Logger '$Logger';

has page_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has page_cc_channel_name => (
  is => 'ro',
  isa => 'Str',
  default => 'slack',
);

has pushover_channel_name => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_pushover_channel',
);

async sub start ($self) {
  my $name = $self->page_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no page channel ($name) configured, cowardly giving up")
    unless $channel;

  return;
}

command page => {
  help => <<'END'
*page* tries to page somebody via their phone or pager.  This is generally
reserved for emergencies or at least "nobody is replying in chat!"

• *page `WHO`: `MESSAGE`*: send this message to that person's phone or pager
END
} => async sub ($self, $event, $rest) {
  my ($who, $what) = $event->text =~ m/^page\s+@?([a-z]+):?\s+(.*)/is;

  unless (length $who and length $what) {
    return await $event->error_reply("usage: page USER: MESSAGE");
  }

  my @to_page;
  if ($who eq 'oncall') {
    my $pd = $self->hub->reactor_named('pagerduty');

    if ($pd) {
      # Really, this should be able to use $pd->oncall_list, but that isn't set
      # eagerly enough.  That should probably be made into a lazily cached
      # attribute like we use for (for example) the Slack user list.  But we
      # can do that in the future. -- rjbs, 2023-10-18
      my @oncall_ids = await $pd->_current_oncall_ids;
      @to_page = grep {; $_ } map {; $pd->username_from_pd($_) } @oncall_ids;
    } else {
      $Logger->log("Unable to find reactor 'pagerduty'") unless $pd;
    }
  } else {
    push @to_page, $who;
  }

  unless (@to_page) {
    # This happens if there are zero members of oncall, for example.
    return await $event->error_reply("It doesn't look like there's anybody to page!");
  }

  TARGET: for my $who (@to_page) {
    $Logger->log("paging $who");
    my $paged = await $self->_do_page($event, $who, $what);

    if ($paged) {
      await $event->reply("Page sent to $who!");
      next TARGET;
    }

    await $event->reply("I don't know how to page $who, sorry.");
  }

  return;
};

async sub _do_page($self, $event, $who, $what) {
  my $user = $self->resolve_name($who, $event->from_user);

  unless ($user) {
    return await $event->error_reply("I don't know who '$who' is. Sorry! 😕");
  }

  my $paged = 0;

  if ($user->has_identity_for($self->page_channel_name) || $user->has_phone) {
    my $to_channel = $self->hub->channel_named($self->page_channel_name);

    my $from = $event->from_user ? $event->from_user->username
                                 : $event->from_address;

    my $want_voice = $self->get_user_preference($user, 'voice-page');

    $to_channel->send_message_to_user(
      $user,
      "$from says: $what",
      ($want_voice
        ? { voice => "Hi, this is Synergy.  You are being paged by $from, who says: $what" }
        : ()),
    );

    $paged = 1;
  }

  if ($user->has_identity_for($self->page_cc_channel_name)) {
    my $to_channel = $self->hub->channel_named($self->page_cc_channel_name);

    my $from = $event->from_user ? $event->from_user->username
                                 : $event->from_address;

    $to_channel->send_message_to_user($user, "You are being paged by $from, who says: $what")
      unless $from eq $user->username;
  }

  if ($self->has_pushover_channel) {
    if ($user->has_identity_for($self->pushover_channel_name)) {
      my $to_channel = $self->hub->channel_named($self->pushover_channel_name);

      my $from = $event->from_user ? $event->from_user->username
                                   : $event->from_address;

      $to_channel->send_message_to_user($user, "$from says: $what");

      $paged = 1;
    }
  }

  return $paged;

}

__PACKAGE__->add_preference(
  name      => 'voice-page',
  validator => async sub ($self, $value, @) { return bool_from_text($value) },
  default   => 1,
  help      => "Should paging try make a voice call instead of a text message?",
  description => "Should paging try make a voice call instead of a text message?",
);

1;
