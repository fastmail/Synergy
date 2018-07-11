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
      name      => 'doing',
      method    => 'handle_doing',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /^doing\s+/i
      },
    },
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
    doings  => $self->_user_doings,
  };
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if ($state->{chatter}) {
      $self->_last_chatter->%* = $state->{chatter}->%*;
    }

    if ($state->{doings}) {
      $self->_user_doings->%* = $state->{doings}->%*;
    }
  }
};

sub user_status_for ($self, $event, $user) {
  return (
    $self->_doing_status($event, $user),
    $self->_business_hours_status($event, $user),
    $self->_chatter_status($event, $user),
  );
}

sub _doing_status ($self, $event, $user) {
  return unless my $doing = $self->doing_for_user($user);

  my $ago = time - $doing->{since};
  $ago -= $ago % 60;

  my $reply =  sprintf "Since %s, doing: %s", ago($ago), $doing->{desc};

  return $event->reply($reply);
}

sub _business_hours_status ($self, $event, $user) {
  my $hours = $self->hub->user_directory->get_user_preference(
    $user,
    'business-hours',
  );

  return unless $hours;

  my $target_tz = $user->time_zone;
  my $now       = DateTime->now(time_zone => $target_tz);
  my $dow = [ qw(sun mon tue wed thu fri sat) ]->[ $now->day_of_week % 7 ];
  my $today_hrs = $hours->{$dow};

  unless ($today_hrs) {
    return sprintf "It's outside of %s's normal business hours.",
      $user->username;
  }

  my $time = $now->format_cldr('HH:mm');

  if ($time lt $today_hrs->{start} or $time gt $today_hrs->{end}) {
    return sprintf "It's outside of %s's normal business hours.",
      $user->username;
  }

  return sprintf "It's currently %s's normal business hours.",
    $user->username;
}

sub _chatter_status ($self, $event, $user) {
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

    my (@statuses) = $comp->user_status_for($event, $who);

    for my $status (grep { defined } @statuses) {
      if (ref $status) {
        $plain .= "$status->{plain}\n";
        $slack .= "$status->{slack}\n";
      } else {
        $plain .= "$status\n";
        $slack .= "$status\n";
      }
    }
  }

  chomp $plain;
  chomp $slack;

  for ($plain, $slack) {
    $_ ||= sprintf "I don't have any information about %s at all!",
      $who->username;
  }

  $event->reply(
    $plain,
    {
      slack => {
        text         => $slack,
        unfurl_links => \0,
        unfurl_media => \0,
      }
    }
  );
}

has _user_doings => (
  is  => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

sub doing_for_user ($self, $user) {
  return unless my $doing = $self->_user_doings->{ $user->username };
  return if $doing->{until} && $doing->{until} < time;
  return $doing;
}

# doing STATUS /opts
sub handle_doing ($self, $event) {
  $event->mark_handled;

  my $text = $event->text;
  $text =~ s/\Adoing\s+//i;

  my ($desc, $switches) = split m{/}, $text, 2;

  if ($desc eq 'nothing' && ! $switches) {
    delete $self->_user_doings->{ $event->from_user->username };
    return $event->reply("Okay, back to business as usual.");
  }

  my $doing = { since => time, desc => $desc };

  SWITCH: for my $switch (split m{\s+/}, $switches) {
    my ($name, $value) = split /\s+/, $switch, 2;

    if ($name eq 'u' or $name eq 'until') {
      my $dt = eval { parse_date_for_user($value, $event->from_user) };
      unless ($dt) {
        return $event->reply("I didn't understand your /until switch.");
      }
      $doing->{until} = $dt->epoch;
      next SWITCH;
    }

    return $event->reply(qq{I don't understand the "/$name" switch.});
  }

  $self->_user_doings->{ $event->from_user->username } = $doing;

  return $event->reply("Thanks for letting me know what you're doing!");
}

1;
