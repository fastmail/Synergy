use v5.24.0;
package Synergy::UserDirectory;
use Moose;

use experimental qw(signatures);
use namespace::autoclean;
use YAML::XS;
use Path::Tiny;
use Synergy::User;

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

sub resolve_user ($self, $channel_name, $user) {
  for my $u ($self->users) {
    if (($u->identities->{$channel_name} // '') eq $user) {
      return $u;
    }
  }

  return undef;
}

sub load_users_from_file ($self, $file) {
  my $user_config = YAML::XS::LoadFile($file);

  my %users;

  for my $username (keys %$user_config) {
    $users{$username} = Synergy::User->new({
      $user_config->{$username}->%*,
      username => $username,
    });
  }

  return \%users;
}

1;
