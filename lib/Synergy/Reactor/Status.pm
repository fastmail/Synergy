use v5.28.0;
use warnings;
package Synergy::Reactor::Status;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::ProvidesUserStatus';

use utf8;
use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);
use Synergy::Util qw(parse_time_hunk day_name_from_abbr);
use Time::Duration::Parse;
use Time::Duration;

sub listener_specs ($reactor) {
  return (
    {
      name      => 'doing',
      method    => 'handle_doing',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /^doing\s+/i },
      help_entries => [
        { title => 'doing',
          text  => "doing SOMETHING: set what you're doing; something can end with some options, like…
• /for DURATION - only keep this status for a while
• /until TIME - like /for, but takes a time, not a duration
• /dnd - while this status is in effect, suppress nagging",
        },
        { title => 'doing',
          text  => "doing nothing: clear any doings you had in place",
        }
      ],
    },
    {
      name      => 'status',
      method    => 'handle_status',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) {
        $e->text =~ /^status\s+(for\s+)?@?(\w+)\s*$/i
      },
      help_entries => [
        { title => 'status',
          text  => "status for USER: see what the user has been up to", }
      ],
    },
    {
      name      => "listen-for-chatter",
      method    => "handle_chatter",
      predicate => sub ($self, $e) { $e->is_public; },
      allow_empty_help => 1,
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
  return unless $event->from_user;

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
      my $doings = $self->_user_doings;

      %$doings = $state->{doings}->%*;

      {
        # XXX Temporary upgrade code, should only need to run once.
        # -- rjbs, 2018-07-13
        my $upgraded;
        for my $username (keys %$doings) {
          if ($doings->{$username} && ref $doings->{$username} eq 'HASH') {
            $doings->{$username} = [ $doings->{$username} ];
            $upgraded = 1;
          }
        }

        $self->save_state if $upgraded;
      }
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
  return unless my @doings = $self->doings_for_user($user);

  @doings = (
    (grep {; ! $_->{until} } @doings),
    (sort {; $a->{until} <=> $b->{until} } grep {; $_->{until} } @doings),
  );

  # If you've let it sit that long, it's probably bunk now. -- rjbs, 2020-12-23
  @doings = grep {; time - $_->{since} < 5 * 86_400 } @doings;

  my $from_user = $event->from_user;
  my $reply = q{};

  for my $doing (@doings) {
    my $ago = time - $doing->{since};
    $ago -= $ago % 60;

    $reply .= sprintf "Since %s, %sdoing: %s\n",
      ago($ago),
      ($doing->{until}
        ? ("until " . $from_user->format_timestamp($doing->{until}) . ", ")
        : q{}),
      $doing->{desc} . ($doing->{dnd} ? ' (dnd)' : '');
  }

  chomp $reply;
  return $reply;
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
    return sprintf "%s doesn't work on %ss.",
      $user->they, $now->day_name;
  }

  my $shift = $user->shift_for_day($self->hub, $now);

  my $time  = $now->format_cldr('HH:mm');

  if ($time lt $today_hrs->{start} or $time gt $today_hrs->{end}) {
    if (! $shift) {
      return sprintf "It's outside of %s normal business hours, *and* %s off today.",
        $user->their, $user->theyre;
    }

    return sprintf "It's outside of %s normal business hours.",
      $user->their;
  }

  unless ($shift) {
    return sprintf "%s off today.  Otherwise, it would be inside %s normal business hours.",
      ucfirst $user->theyre, $user->their;
  }

  my $trailer = '';
  if ($user->is_wfh_on($dow)) {
    $trailer = sprintf q{, and usually %s work%s from home on %ss},
      $user->they,
      $user->they eq 'they' ? '' : 's',   # sigh, english
      day_name_from_abbr($dow);
  }

  return sprintf "It's currently %s normal business hours%s.",
    $user->their,
    $trailer,
}

sub _chatter_status ($self, $event, $user) {
  if (my $last = $self->last_chatter_for($user->username)) {
    my $uri  = $last->{uri};
    my $when = $event->from_user->format_timestamp($last->{when});

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
  $event->text =~ /^status\s+(?:for\s+)?@?(\w+)\s*$/i;
  my $who_name = $1;

  my $who = $self->resolve_name($who_name, $event->from_user);

  $event->mark_handled;

  unless ($who) {
    return $event->error_reply(qq{Sorry, I don't know who "$who_name" is.});
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

sub doings_for_user ($self, $user) {
  return unless my $doings = $self->_user_doings->{ $user->username };

  my $now = time;

  # That's right, we'll modify the guts in place while reading them.  I don't
  # even regret this a little.  Yet.  -- rjbs, 2018-07-13
  @$doings = grep {; ! $_->{until} || $_->{until} > $now } @$doings;

  return @$doings;
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

  my %doing = (since => time, desc => $desc);

  if ($switches) {
    SWITCH: for my $switch (split m{\s+/}, $switches) {
      my ($name, $value) = split /\s+/, $switch, 2;

      if ($name eq 'dnd' or $name eq 'chill') {
        return $event->error_reply("/$name doesn't take an argument")
          if length $value;

        $doing{dnd} = 1;
        next SWITCH;
      }

      if ($name eq 'u' or $name eq 'until') {
        my $until = parse_time_hunk("until $value", $event->from_user);

        return $event->error_reply("I didn't understand your /until switch.")
          unless $until;

        return $event->error_reply("Your /until switch seems to be in the past.")
          unless $until > time;

        $doing{until} = $until;
        next SWITCH;
      }

      if ($name eq 'f' or $name eq 'for') {
        my $until = parse_time_hunk("for $value", $event->from_user);

        return $event->error_reply("I didn't understand your /for switch.")
          unless $until;

        return $event->error_reply("Your /for switch seems to go into the past.")
          unless $until > time;

        $doing{until} = $until;
        next SWITCH;
      }

      return $event->error_reply(qq{I don't understand the "/$name" switch.});
    }
  }

  my $doings = $self->_user_doings->{ $event->from_user->username } //= [];

  if ($doing{until}) {
    push @$doings, \%doing;
  } else {
    @$doings = \%doing;
  }

  return $event->reply("Thanks for letting me know what you're doing!");
}

1;
