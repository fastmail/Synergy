use v5.24.0;
package Synergy::UserDirectory;
use Moose;

use experimental qw(signatures);
use namespace::autoclean;
use YAML::XS;
use Path::Tiny;
use Synergy::User;

my $cname = 'SYNERGY_CONFIG';

die "You must set \$$cname to the Synergy config file.\n"
  unless defined $ENV{$cname};

die "Config file '$ENV{$cname}' not found" unless -e $ENV{$cname};

my $config = YAML::XS::LoadFile($ENV{SYNERGY_CONFIG});

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

sub load_user ($self, $username) {
  my $dir = $self->_state_dir && $self->_state_dir->child("users");

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
  my %users;
  my %uconf = %{ $config->{users} };

  for my $username (keys %uconf) {
    my $user = $self->load_user($username);
    $users{$username} = $user;
  }

  return \%users;
}

sub _state_dir {
  return unless $config->{state_dir} && -d $config->{state_dir};
  path($config->{state_dir});
}

sub _state_file {
  return unless $_[0]->_state_dir;
  $_[0]->_state_dir->child("state.json");
}

1;
