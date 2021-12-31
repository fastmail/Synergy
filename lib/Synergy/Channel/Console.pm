use v5.24.0;
use warnings;
package Synergy::Channel::Console;

use utf8;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS;

use Synergy::External::Slack;
use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;

use Term::ANSIColor qw(colored);

with 'Synergy::Role::Channel';

has theme => (
  is  => 'ro',
  isa => 'Str',
);

has from_address => (
  is  => 'ro',
  isa => 'Str',
  default => 'sysop',
);

has default_public_reply_address => (
  is  => 'ro',
  isa => 'Str',
  default => '#public',
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

  open(my $cloned_stdout, ">&STDOUT") or die "Can't dup STDOUT: $!";
  open(my $cloned_stdin , ">&STDIN")  or die "Can't dup STDIN: $!";

  binmode $cloned_stdout, ':pop'; # remove utf8
  binmode $cloned_stdin,  ':pop'; # remove utf8

  my %arg = (
    write_handle => $cloned_stdout,
    encoding     => 'UTF-8',
    # autoflush    => 1,
  );

  unless($channel->send_only) {
    $arg{read_handle} = $cloned_stdin,
    $arg{on_read}     = sub {
      my ( $self, $buffref, $eof ) = @_;

       while( $$buffref =~ s/^(.*\n)// ) {
          my $text = $1;
          chomp $text;

          my $event = $channel->_event_from_text($text);
          next unless $event;

          $channel->hub->handle_event($event);
       }

       return 0;
    };
  }

  return IO::Async::Stream->new(%arg);
}

sub _event_from_text ($self, $text) {
  # Remove any leading "/".  If there's a leading slash, we're just sending a
  # normal message with a leading slash.  (The now-removed slash was here to
  # escape this one.)  Otherwise, we're looking for a Console channel slash
  # command.
  if ($text =~ s{\A/}{} && $text !~ m{\A/}) {
    my ($cmd, $rest) = split /\s+/, $text, 2;

    if (my $code =$self->can("_console_cmd_$cmd")) {
      $self->$code($rest);
      return undef;
    }

    $self->_display_message("No such console command: /$cmd");
    return undef;
  }

  my %arg = (
    type => 'message',
    text => $text,
    was_targeted  => 1,
    is_public     => 0,
    from_channel  => $self,
    from_address  => $self->from_address,
    transport_data => { text => $text },
  );

  if ($arg{text} =~ s/\A \{ ([^}]+?) \} \s+//x) {
    # Crazy format for producing custom events by hand! -- rjbs, 2018-03-16
    #
    # If no colon/value, booleans default to becoming true.
    #
    # f:STRING      -- change the from address
    # d:STRING      -- change the default reply address
    # p[ublic]:BOOL -- set whether is public
    # t:BOOL        -- set whether targeted
    my @flags = split /\s+/, $1;
    FLAG: for my $flag (@flags) {
      my ($k, $v) = split /:/, $flag;

      if ($k eq 'f') {
        unless (defined $v) {
          $Logger->log([
            "console event on %s: ignoring valueless 'f' flag",
            $self->name,
          ]);
          next FLAG;
        }
        $arg{from_address} = $v;
        next FLAG;
      }

      if ($k eq 'd') {
        unless (defined $v) {
          $Logger->log([
            "console event on %s: ignoring valueless 'd' flag",
            $self->name,
          ]);
          next FLAG;
        }
        $arg{transport_data}{default_reply_address} = $v;
        next FLAG;
      }

      if ($k eq 't') {
        $v //= 1;
        $arg{was_targeted} = $v;
        next FLAG;
      }

      if ($k eq substr("public", 0, length $k)) {
        $v //= 1;
        $arg{is_public} = $v;
        next FLAG;
      }
    }
  }

  $arg{conversation_address}
    =   $arg{transport_data}{default_reply_address}
    //= $arg{is_public}
      ? $self->default_public_reply_address
      : $arg{from_address};

  my $user = $self->hub->user_directory->user_by_channel_and_address(
    $self,
    $arg{from_address},
  );

  $arg{from_user} = $user if $user;

  return Synergy::Event->new(\%arg);
}

my %Theme = (
  blue    => [  27,  14 ],
  green   => [  77, 118 ],
  purple  => [ 140, 201 ],
);

sub start ($self) {
  die "bogus theme" if $self->theme && ! $Theme{$self->theme};
  $self->hub->loop->add($self->_stream);
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  $self->send_message($user->username, $text, $alts);
}

sub _format_message ($self, $name, $address, $text) {
  my $theme = $self->theme;

  return ">>> $name!$address > $text\n" unless $theme;

  my @T = $Theme{ $self->theme }->@*;
  return colored([ "ansi$T[0]" ], ">>> ")
       . colored([ "ansi$T[1]" ], $name)
       . colored([ "ansi$T[0]" ], "!")
       . colored([ "ansi$T[1]" ], $address)
       . colored([ "ansi$T[0]" ], " > ")
       . colored([ "ansi$T[1]" ], $text)
       . "\n";
}

sub send_message ($self, $address, $text, $alts = {}) {
  my $name = $self->name;
  print { $self->_stream->write_handle }
    $self->_format_message($name, $address, $text);
  return;
}

sub describe_event ($self, $event) {
  return "(a console event)";
}

sub describe_conversation ($self, $event) {
  return "[console]";
}

1;
