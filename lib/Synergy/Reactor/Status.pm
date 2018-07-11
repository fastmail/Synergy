use v5.24.0;
package Synergy::Reactor::Status;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor', 'Synergy::Role::ProvidesUserStatus';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);
use Time::Duration::Parse;
use Time::Duration;

sub listener_specs ($reactor) {
  return (
    {
      name      => 'status',
      method    => 'handle_status',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /^status\s+(for\s+)?(\w+)\s*$/i
      },
    },
    {
      name      => "listen-for-chatter",
      method    => "handle_chatter",
      predicate => sub ($self, $e) {
        return unless $e->is_public;
        return 1;
      },
    },
  );
}

has monitored_channel_name => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_monitored_channel',
);

has _last_chatter => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub {  {}  },
  traits  => [ 'Hash' ],
  handles => {
    record_last_chatter_for => 'set',
    last_chatter_for        => 'get',
  },
);

sub handle_chatter ($self, $event) {
  return unless $self->has_monitored_channel;
  return unless $self->monitored_channel_name eq $event->from_channel->name;

  my $username = $event->from_user->username;
  $self->record_last_chatter_for($username, {
    when => $event->time,
    uri  => scalar $event->event_uri,
  });

  $self->save_state;

  return;
}

sub state ($self) {
  return {
    chatter => $self->_last_chatter,
  };
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $chatter = $state->{chatter}) {
      $self->_last_chatter->%* = %$chatter;
    }
  }
};

sub user_status_for ($self, $event, $user) {
  if (my $last = $self->last_chatter_for($user->username)) {
    my $uri  = $last->{uri};
    my $when = $event->from_user->format_datetime(
      DateTime->from_epoch(epoch => $last->{when})
    );

    my $link_str = "chatter from " . $user->username;

    return {
      plain => sprintf("I last saw %s at %s%s",
        $link_str, $when, ($uri ? ": $uri" : q{.})),

      slack => sprintf("I last saw %s at %s.",
        ($uri ? "<$uri|$link_str>" : $link_str), $when),
    }
  }

  return sprintf "I've never seen any chatter from %s.", $user->username;
}

sub handle_status ($self, $event) {
  $event->text =~ /^status\s+(?:for\s+)?(\w+)\s*$/i;
  my $who_name = $1;

  my $who = $self->resolve_name($who_name, $event->from_user);

  $event->mark_handled;

  unless ($who) {
    return $event->reply(qq{Sorry, I don't know who "$who_name" is.});
  }

  my $plain = q{};
  my $slack = q{};

  for my $comp ($self->hub->channels, $self->hub->reactors) {
    next unless $comp->does('Synergy::Role::ProvidesUserStatus');

    my $status = $comp->user_status_for($event, $who);

    if (ref $status) {
      $plain .= "$status->{plain}\n";
      $slack .= "$status->{slack}\n";
    } else {
      $plain .= "$status\n";
      $slack .= "$status\n";
    }
  }

  chomp $plain;
  chomp $slack;

  for ($plain, $slack) {
    $_ ||= sprintf "I don't have any information about %s at all!",
      $who->username;
  }

  $event->reply($plain, { slack => $slack });
}

1;
