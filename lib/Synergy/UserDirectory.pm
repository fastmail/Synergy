use v5.24.0;
package Synergy::UserDirectory;
use Moose;

with 'Synergy::Role::HubComponent';
with 'Synergy::Role::HasPreferences' => {
  namespace => 'user',
};

use experimental qw(signatures);
use namespace::autoclean;
use YAML::XS;
use Path::Tiny;
use Synergy::User;
use Synergy::Logger '$Logger';
use List::Util qw(first);

has users => (
  isa  => 'HashRef',
  traits  => [ 'Hash' ],
  handles => {
    users      => 'values',
    user_named => 'get',
    usernames  => 'keys',
    _set_user  => 'set',
  },
  clearer => '_clear_users',
  writer  => '_set_users',
  default => sub {  {}  },
);


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
    $user_config = JSON->new->decode( Path::Tiny::path($file)->slurp );
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

  return $user;
}

__PACKAGE__->add_preference(
  name => 'realname',
  validator => sub { "$_[0]" },
  after_set => sub ($self, $username, $value) {
    $self->reload_user($username, { realname => $value });
  },
);

# Temporary, presumably. We're assuming here that the values from git are
# valid. This routine loads up our preferences from the user object, unless we
# already have a better preference saved for them.
sub load_preferences_from_user ($self, $username) {
  $Logger->log([ "Loading global preferences for %s", $username ]);
  my $user = $self->user_named($username);

  my $existing_real = $user->has_realname ? $user->realname : undef;
  my $existing_pref = $self->get_user_preference($user, 'realname');

  # If the user doesn't have an existing preference, always update.
  if ($existing_real && ! $existing_pref) {
    warn "setting preference";
    $self->set_user_preference($user, 'realname', $existing_real);
  }

  # If the user *does* have an existing preference, and it's just their
  # username, overwrite it.
  if ($existing_pref && $existing_pref eq $username && $existing_real) {
    warn "setting preference";
    $self->set_user_preference($user, 'realname', $existing_real);
  }
}

1;
