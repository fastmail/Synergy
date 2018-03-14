use v5.24.0;
package Synergy::UserDirectory;
use Moose;

use experimental qw(signatures);
use namespace::autoclean;
use YAML::XS;
use Path::Tiny;
use Synergy::User;

has config_file => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => undef,
);

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
  builder => 'load_users',
);

sub resolve_user ($self, $channel_name, $user) {
  for my $u ($self->users) {
    if (($u->identities->{$channel_name} // '') eq $user) {
      return $u;
    }
  }

  return undef;
}

sub load_user ($self, $state_dir, $username) {
  my $dir = $state_dir->child("users");

  my %uconf;

  my $file = $dir && $dir->child("$username.yaml");
  if ($file && -e $file) {
    my $doc = YAML::XS::LoadFile("$file");
    %uconf = %$doc;
  }

  return Synergy::User->new({
    %uconf,
    username => $username,
  });
}

sub load_users ($self) {
  return {} unless $self->config_file;

  my $config = YAML::XS::LoadFile($self->config_file);
  return {} unless $config->{state_dir};
  my $state_dir = path($config->{state_dir});

  my %users;
  my %uconf = %{ $config->{users} };

  for my $username (keys %uconf) {
    my $user = $self->load_user($state_dir, $username);
    $users{$username} = $user;
  }

  return \%users;
}

1;
