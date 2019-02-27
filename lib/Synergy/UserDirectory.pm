use v5.24.0;
use warnings;
package Synergy::UserDirectory;
use Moose;

with 'Synergy::Role::HubComponent';
with 'Synergy::Role::HasPreferences' => {
  namespace => 'user',
};

use experimental qw(signatures lexical_subs);
use namespace::autoclean;
use JSON::MaybeXS ();
use YAML::XS;
use Path::Tiny;
use Synergy::User;
use Synergy::Util qw(known_alphabets);
use Synergy::Logger '$Logger';
use List::Util qw(first shuffle all);
use DateTime;
use utf8;

has _users => (
  isa  => 'HashRef',
  traits  => [ 'Hash' ],
  handles => {
    all_users  => 'values',
    user_named => 'get',
    usernames  => 'keys',
    _set_user  => 'set',
  },
  clearer => '_clear_users',
  writer  => '_set_users',
  default => sub {  {}  },
);

sub users ($self) {
  return grep {; ! $_->is_deleted } $self->all_users;
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }
  }
};

sub state ($self) {
  return { preferences => $self->user_preferences };
}

sub master_users ($self) {
  return grep {; $_->is_master } $self->users;
}

sub user_by_channel_and_address ($self, $channel_name, $address) {
  $channel_name = $channel_name->name
    if blessed $channel_name && $channel_name->does('Synergy::Role::Channel');

  for my $u ($self->users) {
    if ((($u->identities // {})->{$channel_name} // '') eq $address) {
      return $u;
    }
  }

  return undef;
}

sub user_by_name ($self, $name) {
  # XXX - probably just put user_by_name in handles
  return $self->user_named($name);
}

sub user_by_nickname ($self, $name) {
  return first {;
    grep {; lc $_ eq lc $name } $_->nicknames
  } $self->users;
}

sub load_users_from_file ($self, $file) {
  my $user_config;
  if ($file =~ /\.ya?ml\z/) {
    $user_config = YAML::XS::LoadFile($file);
  } elsif ($file =~ /\.json\z/) {
    $user_config = JSON::MaybeXS->new->decode( Path::Tiny::path($file)->slurp );
  } else {
    Carp::confess("unknown filetype: $file");
  }

  my %users;

  for my $username (keys %$user_config) {
    $users{$username} = Synergy::User->new({
      $user_config->{$username}->%*,
      username => $username,
      directory => $self,
    });
  }

  $self->_set_users(\%users);

  return \%users;
}

sub reload_user ($self, $username, $data) {
  my $old = $self->user_named($username);

  my $new_user = Synergy::User->new({
    %$old,
    %$data,
    username => $username,
  });

  $self->_set_user($username, $new_user);
}

sub resolve_name ($self, $name, $resolving_user) {
  return unless $name;

  $name = lc $name;

  return $resolving_user
    if $name eq 'me' || $name eq 'my' || $name eq 'myself' || $name eq 'i';

  my $user = $self->user_named($name);

  unless ($user) {
    ($user) = grep {; grep { $_ eq $name } $_->nicknames } $self->users;
  }

  # deleted users don't resolve
  return undef if $user && $user->is_deleted;

  return $user;
}

my $Alphabets = join q{, }, sort { $a cmp $b } known_alphabets();

__PACKAGE__->add_preference(
  name        => 'alphabet',
  help        => "Preferred alphabet (default: Latin): One of: $Alphabets",
  description => "Preferred alphabet for responses",
  validator   => sub ($value) {
    my ($known) = grep {; lc $_ eq lc $value } known_alphabets;
    return $known if $known;
    return (undef, "alphabet must be one of $Alphabets");
  },
  default     => 'English',
);

__PACKAGE__->add_preference(
  name => 'realname',
  validator => sub { "$_[0]" },
  after_set => sub ($self, $username, $value) {
    $self->reload_user($username, { realname => $value });
  },
);

__PACKAGE__->add_preference(
  name => 'nicknames',
  help => 'one or more comma-separated aliases',
  description => "alternate names for a person",
  default => sub { [] },
  validator => sub ($value) {
    my @names = map  {; lc $_    }
                grep { length $_ }
                split /\s*,\s*/, $value;

    unless (all { /^[a-z0-9]+$/ } @names) {
      return (undef, "nicknames must be all ascii characters with no spaces");
    }

    return \@names;
  },
  describer => sub ($value) {
    return '<undef>' unless $value;
    return join(q{, }, @$value);
  },
);

__PACKAGE__->add_preference(
  name => 'pronoun',
  help => q{This is the pronoun you'd prefer to be used for you.},
  description => 'preferred personal pronoun (nominative case)',
  validator => sub ($value) {
    my %valid_pronouns = map { $_ => 1 } qw(he she they);

    $value =~ s/\s*//g;
    $value = lc $value;

    unless (exists $valid_pronouns{$value}) {
      my @p = shuffle keys %valid_pronouns;
      my $d = "(If these words don't describe you, let us know and we'll get some that do!)";
      return (undef, "Valid values are: $p[0], $p[1], or $p[2]. $d");
    }

    return $value;
  },
);

__PACKAGE__->add_preference(
  name => 'time-zone',
  validator => sub ($value) {
    my $err = qq{"$value" doesn't look like a valid time zone name};

    eval { DateTime->now(time_zone => $value) };
    return (undef, $err) if $@ =~ /invalid name/;

    return $value;
  },
);

__PACKAGE__->add_preference(
  name => 'business-hours',
  describer => sub ($value) {
    my @wdays = qw(mon tue wed thu fri);
    my @wends = qw(sat sun);

    my %desc = map {; keys($value->{$_}->%*)
                      ? ($_ => "$value->{$_}{start}-$value->{$_}{end}")
                      : () } (@wdays, @wends);

    return "None" unless %desc;

    if ($desc{mon} && 7 == grep {; $desc{$_} eq $desc{mon} } (@wdays, @wends)) {
      $desc{everyday} = $desc{mon};
      delete @desc{ @wdays };
      delete @desc{ @wends };
    }

    if ($desc{mon} && 5 == grep {; $desc{$_} eq $desc{mon} } @wdays) {
      $desc{weekdays} = $desc{mon};
      delete @desc{ @wdays };
    }

    if ($desc{sat} && 2 == grep {; $desc{$_} eq $desc{sat} } @wends) {
      $desc{weekends} = $desc{sat};
      delete @desc{ @wends };
    }

    return join q{, }, map {; $desc{$_} ? "\u$_: $desc{$_}" : () }
      (qw(weekdays sun), @wdays, qw(sat weekends));
  },
  validator => sub ($value) {
    my $err = q{you can use "weekdays, 09:00-17:00" or "Mon: 09:00-17:00, Tue: 10:00-12:00, (etc.)"};

    my sub validate_start_end ($start, $end) {
      my ($start_h, $start_m) = split /:/, $start, 2;
      my ($end_h, $end_m) = split /:/, $end, 2;

      return undef if $end_h <= $start_h || $start_m >= 60 || $end_m >= 60;

      return {
        start => sprintf("%02d:%02d", $start_h, $start_m),
        end   => sprintf("%02d:%02d", $end_h, $end_m),
      };
    }

    if ($value =~ /^weekdays/i) {
      my ($start, $end) =
        $value =~ m{
          \Aweekdays,?
          \s+
          ([0-9]{1,2}:[0-9]{2})
          \s*
          (?:to|-)
          \s*
          ([0-9]{1,2}:[0-9]{2})
        }ix;

      return (undef, $err) unless $start && $end;

      my $struct = validate_start_end($start, $end);
      return (undef, $err) unless $struct;

      return {
        mon => $struct,
        tue => $struct,
        wed => $struct,
        thu => $struct,
        fri => $struct,
        sat => {},
        sun => {},
      };
    }

    my @hunks = split /,\s+/, $value;
    return (undef, $err) unless @hunks;

    my %week_struct = map {; $_ => {} } qw(mon tue wed thu fri sat sun);

    for my $hunk (@hunks) {
      my ($day, $start, $end) =
        $hunk =~ m{
          \A
          ([a-z]{3}):
          \s*
          ([0-9]{1,2}:[0-9]{2})
          \s*
          (?:to|-)
          \s*
          ([0-9]{1,2}:[0-9]{2})
        }ix;

      return (undef, $err) unless $day && $start && $end;
      return (undef, $err) unless $week_struct{ lc $day };

      my $day_struct = validate_start_end($start, $end);
      return (undef, $err) unless $day_struct;

      $week_struct{ lc $day } = $day_struct;
    }

    return \%week_struct;
  },
);

# Temporary, presumably. We're assuming here that the values from git are
# valid. This routine loads up our preferences from the user object, unless we
# already have a better preference saved for them.
sub load_preferences_from_user ($self, $username) {
  $Logger->log_debug([ "Loading global preferences for %s", $username ]);
  my $user = $self->user_named($username);

  $self->set_user_preference($user, 'time-zone', $user->_time_zone)
    unless $self->user_has_preference($user, 'time-zone');

  my $existing_real = $user->has_realname ? $user->realname : undef;
  my $existing_pref = $self->get_user_preference($user, 'realname');

  # If the user doesn't have an existing preference, always update.
  if ($existing_real && ! $existing_pref) {
    $self->set_user_preference($user, 'realname', $existing_real);
  }

  # If the user *does* have an existing preference, and it's just their
  # username, overwrite it.
  if ($existing_pref && $existing_pref eq $username && $existing_real) {
    $self->set_user_preference($user, 'realname', $existing_real);
  }

  unless ($self->user_has_preference($user, 'nicknames')) {
    my @nicks = $user->nicknames;
    $self->set_user_preference($user, 'nicknames', \@nicks);
  }
}

1;
