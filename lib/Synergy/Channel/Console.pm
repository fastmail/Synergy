use v5.24.0;
package Synergy::Channel::Console;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS;

use Synergy::External::Slack;
use Synergy::Event;
use Synergy::ReplyChannel;
use Synergy::Logger '$Logger';

use namespace::autoclean;
use Data::Dumper::Concise;

with 'Synergy::Role::Channel';

has from_address => (
  is  => 'ro',
  isa => 'Str',
  default => 'sysop',
);

has send_only => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has stream => (
  reader    => '_stream',
  init_arg  => undef,
  lazy      => 1,
  builder   => '_build_stream',
);

sub _build_stream {
  my ($channel) = @_;
  Scalar::Util::weaken($channel);

  my %arg = (
    write_handle => \*STDOUT,
    autoflush    => 1,
  );

  unless($channel->send_only) {
    $arg{read_handle} = \*STDIN;
    $arg{on_read}     = sub {
      my ( $self, $buffref, $eof ) = @_;

       while( $$buffref =~ s/^(.*\n)// ) {
          my $text = $1;
          chomp $text;

          my $user = $channel->hub->user_directory->user_by_channel_and_address(
            $channel,
            $channel->from_address,
          );

          my $evt = Synergy::Event->new({
            type => 'message',
            text => $text,
            was_targeted  => 1,
            is_public     => 0,
            from_channel  => $channel,
            from_address  => $channel->from_address,
            ( $user ? ( from_user => $user ) : () ),
            transport_data => $text,
          });

          my $rch = Synergy::ReplyChannel->new(
            channel => $channel,
            prefix  => ($user ? $user->username : $channel->from_address) . ": ",
            default_address => $channel->from_address,
            private_address => $channel->from_address,
          );

          $channel->hub->handle_event($evt, $rch);
       }

       return 0;
    };
  }

  return IO::Async::Stream->new(%arg);
}

sub start ($self) {
  $self->hub->loop->add($self->_stream);
}

sub send_message_to_user ($self, $user, $text) {
  $self->send_text($user->username, $text);
}

sub send_text ($self, $address, $text) {
  my $name = $self->name;
  $self->_stream->write(">>> $name!$address > $text\n");
  return;
}

sub describe_event ($self, $event) {
  return "(a console event)";
}

1;
