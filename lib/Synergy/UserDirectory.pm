use v5.28.0;
use warnings;
package Synergy::UserDirectory;
use Moose;

with (
  'Synergy::Role::ManagesState',
  'Synergy::Role::HasPreferences' => {
    namespace => 'user',
  },
);

use experimental qw(signatures lexical_subs);
use namespace::autoclean;
use Path::Tiny;
use Synergy::User;
use Synergy::Util qw(known_alphabets read_config_file day_name_from_abbr);
use Synergy::Logger '$Logger';
use Lingua::EN::Inflect qw(WORDLIST);
use List::Util qw(first shuffle all);
use DateTime;
use Defined::KV;
use Try::Tiny;
use utf8;

has name => (
  is  => 'ro',
  isa => 'Str',
  default => '_user_directory',
);

sub env;
has env => (
  is  => 'ro',
  isa => 'Synergy::Environment',
  required => 1,
  weak_ref => 1,
);

has _users => (
  isa  => 'HashRef',
  traits  => [ 'Hash' ],
  handles => {
    all_users       => 'values',
    all_usernames   => 'keys',
    _any_user_named => 'get',
    _set_user       => 'set',
    _user_pairs     => 'kv',
  },
  clearer => '_clear_users',
  writer  => '_set_users',
  default => sub {  {}  },
);

has _active_users => (
  isa  => 'HashRef',
  traits  => [ 'Hash' ],
  handles => {
    users      => 'values',
    user_named => 'get',
    usernames  => 'keys',
  },
  lazy => 1,
  clearer => '_clear_active_users',
  default => sub ($self) {
    my %active;

    for my $pair ($self->_user_pairs) {
      my ($name, $user) = @$pair;
      next if $user->is_deleted;
      $active{$name} = $user;
    }

    return \%active;
  },
);

after _set_user  => sub ($self, @) { $self->_clear_active_users };
after _set_users => sub ($self, @) { $self->_clear_active_users };

sub state ($self) { return {} }

# HasPreferences calls this as $self->save_state, because it's normally used
# on hub components, which handle all of that.
around save_state => sub ($orig, $self) {
  $self->$orig($self->name, $self->state);
};

sub master_users ($self) {
  return grep {; $_->is_master } $self->users;
}

sub master_user_string ($self, $conj = 'or') {
  my @masters = map {; $_->username } $self->master_users;

  return $masters[0] if @masters == 1;
  return "$masters[0] $conj $masters[1]" if @masters == 2;

  $masters[-1] = "$conj " . $masters[-1];
  return join(', ', @masters);
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

# NOTE: This is a hack. It's here because I want to make sure for reactors
# with preferences, you never have to remember to call ->fetch_state on
# startup to load the prefs (...because I never remember to do so). That means
# I need somewhere to hook that around() call. register_with_hub is convenient
# for channels and reactors, because they all get it, but the UserDirectory is
# weird and manages state but _isn't_ a HubComponent. Rather than work out
# exactly what to do here, we'll just install a stub register_with_hub, which
# is only called in the modifier in HasPreferences.
# -- michael, 2021-12-10
sub register_with_hub {}

sub load_users_from_database ($self) {
  my $dbh = $self->env->state_dbh;
  my %users;

  # load prefs
  $self->fetch_state($self->name);

  my $user_sth = $dbh->prepare('SELECT * FROM users');
  $user_sth->execute;

  while (my $row = $user_sth->fetchrow_hashref) {
    my $username = $row->{username};
    $users{$username} = Synergy::User->new({
      directory => $self,
      username  => $username,
      defined_kv(is_master  => $row->{is_master}),
      defined_kv(is_virtual => $row->{is_virtual}),
      defined_kv(deleted    => $row->{is_deleted}),
      defined_kv(lp_id      => $row->{lp_id}),
    });
  }

  my $identity_sth = $dbh->prepare('SELECT * FROM user_identities');
  $identity_sth->execute;

  while (my $row = $identity_sth->fetchrow_hashref) {
    my $username = $row->{username};
    my $user = $users{$username};

    unless ($user) {
      $Logger->log(["Found identity for %s, but no matching user!", $username]);
      next;
    }

    $user->add_identity($row->{identity_name}, $row->{identity_value});
  }

  $self->_set_users(\%users);
  return \%users;
}

# The source of truth will now be the sqlite database. But if we have a user
# file anyway, we'll update the database (so we'll be right next time) and
# load this user directly.
sub load_users_from_file ($self, $filename) {
  my $user_config = read_config_file($filename);

  for my $username (keys %$user_config) {
    if ($self->user_named($username)) {
      $Logger->log_debug([
        "Tried to load user %s from file, but already existed in user db",
        $username,
      ]);
      next;
    }

    my $uconfig = $user_config->{$username};

    my $user = Synergy::User->new({
      $uconfig->%*,
      username => $username,
      directory => $self,
    });

    $self->register_user($user);
  }
}

# Save them in memory, and also insert them into the database.
sub register_user ($self, $user) {
  my $dbh = $self->env->state_dbh;
  state $user_insert_sth = $dbh->prepare(join(q{ },
    q{INSERT INTO users},
    q{   (username, lp_id, is_master, is_virtual, is_deleted)},
    q{VALUES (?,?,?,?,?)}
  ));

  state $identity_insert_sth = $dbh->prepare(join(q{ },
    q{INSERT INTO user_identities (username, identity_name, identity_value)},
    q{VALUES (?,?,?)}
  ));

  $Logger->log(['registering user %s', $user->username]);

  # Save these for next time.
  my $ok = 0;
  $dbh->begin_work;
  try {
    $user_insert_sth->execute(
      $user->username,
      $user->lp_id,
      $user->is_master,
      $user->is_virtual,
      $user->is_deleted,
    );

    for my $pair ($user->identity_pairs) {
      $identity_insert_sth->execute($user->username, $pair->[0], $pair->[1]);
    }

    $self->_set_user($user->username, $user);
    $dbh->commit;
    $ok = 1;
  } catch {
    my $err = $_;
    $dbh->rollback;

    $Logger->log(["Error while registering user: %s", $err]);
    $ok = 0;
  };

  return $ok;
}

sub set_lp_id_for_user ($self, $user, $lp_id) {
  my $dbh = $self->env->state_dbh;
  my $user_update_sth = $dbh->prepare(
    q{UPDATE users SET lp_id = ? WHERE username = ?},
  );

  $Logger->log(['registering lp id %s for %s', $lp_id, $user->username]);
  $user_update_sth->execute($lp_id, $user->username);
  return;
}

sub reload_user ($self, $username, $data) {
  my $old = $self->_any_user_named($username);

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
  $name =~ s/^@//;

  return $resolving_user
    if $name eq 'me' || $name eq 'my' || $name eq 'myself' || $name eq 'i';

  my $user = $self->user_named($name);

  unless ($user) {
    ($user) = grep {; grep { $_ eq $name } $_->nicknames } $self->users;
  }

  return $user;
}

my $Alphabets = join q{, }, sort { $a cmp $b } known_alphabets();

__PACKAGE__->add_preference(
  name        => 'alphabet',
  help        => "Preferred alphabet (default: Latin): One of: $Alphabets",
  description => "Preferred alphabet for responses",
  validator   => sub ($self, $value, @) {
    my ($known) = grep {; lc $_ eq lc $value } known_alphabets;
    return $known if $known;
    return (undef, "alphabet must be one of $Alphabets");
  },
  default     => 'English',
);

__PACKAGE__->add_preference(
  name        => 'phone',
  description => 'your phone number',
  help        => 'Your phone number, in the form +1NNNNNNNNNN',
  validator   => sub ($self, $value, $event) {
    # clear: allow undef, but no error
    return undef unless defined $value;

    # dumb validation
    my $err = 'phone number must be all digits, beginning with +';
    $value =~ s/^\s*|\s*$//g;

    return (undef, $err) unless $value =~ /^\+[0-9]+$/;
    return "$value";
  },
);

__PACKAGE__->add_preference(
  name => 'realname',
  validator => sub { "$_[1]" },
  after_set => sub ($self, $username, $value) {
    $self->reload_user($username, { realname => $value });
  },
);

__PACKAGE__->add_preference(
  name => 'nicknames',
  help => 'one or more comma-separated aliases',
  description => "alternate names for a person",
  default => sub { [] },
  validator => sub ($self, $value, $event) {
    my @names = map  {; lc $_    }
                grep { length $_ }
                split /\s*,\s*/, $value;

    unless (all { /^[a-z0-9]+$/ } @names) {
      return (undef, "nicknames must be all ascii characters with no spaces");
    }

    my @taken = grep {;
      my $user = $self->resolve_name($_, $event->from_user);
      $user && lc $user->username ne lc $event->from_user->username;
    } @names;

    if (@taken) {
      return (undef, "Sorry, these nicknames were already taken: @taken");
    }

    return \@names;
  },
  describer => sub ($value) {
    return '<undef>' unless $value;
    return '<undef>' unless @$value;
    return join(q{, }, @$value);
  },
);

__PACKAGE__->add_preference(
  name => 'pronoun',
  help => q{This is the pronoun you'd prefer to be used for you.},
  description => 'preferred personal pronoun (nominative case)',
  validator => sub ($self, $value, @) {
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
  validator => sub ($self, $value, @) {
    my $err = qq{"$value" doesn't look like a valid time zone name};

    eval { DateTime->now(time_zone => $value) };
    if (my $ex = $@) {
      $Logger->log(['Parsing time zone name "%s" threw an exception: %s', $value, $ex]);
      return (undef, $err);
    }

    return $value;
  },
);

__PACKAGE__->add_preference(
  name => 'business-hours',
  help      => q{when you work; you can use "weekdays, 09:00-17:00" or "Mon: 09:00-17:00, Tue: 10:00-12:00, (etc.)"},
  describer => \&Synergy::Util::describe_business_hours,
  validator => sub ($self, $value, @) {
    return Synergy::Util::validate_business_hours($value);
  },
);

__PACKAGE__->add_preference(
  name => 'wfh-days',
  help      => q{days you work regularly from home; use "Wed, Fri" (etc.)"},
  default   => sub { [] },
  describer => sub ($value) {
    my @all = map {; day_name_from_abbr($_) } @$value;
    return @all ? WORDLIST(@all) : '<none>';
  },
  validator => sub ($self, $value, @) {
    my @known = qw(mon tue wed thu fri sat sun);
    my %is_valid = map {; $_ => 1 } @known;

    my @got = split /[,;]\s+/, lc $value;

    return [] if @got == 1 and $got[0] eq 'none';

    my @bad = grep {; ! $is_valid{$_} } @got;
    if (@bad) {
      my $err = q{use 3-letter day abbreviations, separated with commas, like "Wed, Fri" (or "none")};
      return (undef, $err);
    }

    return \@got;
  },
);

1;
