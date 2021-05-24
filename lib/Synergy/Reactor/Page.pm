use v5.24.0;
use warnings;
package Synergy::Reactor::Page;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use utf8;

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

has page_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has pushover_channel_name => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_pushover_channel',
);

sub listener_specs {
  return {
    name      => 'page',
    method    => 'handle_page',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^page/i },
    help_entries => [
      { title => 'page', text => <<'END'
*page* tries to page somebody via their phone or pager.  This is generally
reserved for emergencies or at least "nobody is replying in chat!"

• *page `WHO`: `MESSAGE`*: send this message to that person's phone or pager
END
      },
    ],
  };
}

sub start ($self) {
  my $name = $self->page_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no page channel ($name) configured, cowardly giving up")
    unless $channel;
}

sub handle_page ($self, $event) {
  $event->mark_handled;

  my ($who, $what) = $event->text =~ m/^page\s+@?([a-z]+):?\s+(.*)/is;

  unless (length $who and length $what) {
    $event->error_reply("usage: page USER: MESSAGE");
    return;
  }

  my $user = $self->resolve_name($who, $event->from_user);

  unless ($user) {
    $event->error_reply("I don't know who '$who' is. Sorry :confused:");
    return;
  }

  my $paged = 0;

  if ($user->has_identity_for($self->page_channel_name) || $user->has_phone) {
    my $to_channel = $self->hub->channel_named($self->page_channel_name);

    my $from = $event->from_user ? $event->from_user->username
                                 : $event->from_address;

    $to_channel->send_message_to_user($user, "$from says: $what");

    $paged = 1;
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

  if ( $paged ) {
    $event->reply("Page sent!");
  }
  else {
    $event->reply("I don't know how to page $who, sorry.");
  }
}

1;
