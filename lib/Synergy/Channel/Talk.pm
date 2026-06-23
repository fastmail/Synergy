use v5.24.0;
use warnings;
package Synergy::Channel::Talk;

use Moose;
use experimental qw(signatures);
use IO::Async::Socket;
use Socket qw(inet_ntoa inet_aton unpack_sockaddr_in pack_sockaddr_in);
use Text::Unidecode;

use Synergy::Logger '$Logger';

use Synergy::Event;

use namespace::autoclean;

with 'Synergy::Role::Channel';


# This is a channel to let you talk to Synergy via, uh, talk(1).
#
# The "protocol" is basically undocumented outside of the talk(1) and talkd(8)
# source. I encourage you to take a look. Its very simple and easy to read.
#
# The basic idea is that one talk(1) client will connect to another via TCP,
# and they exchange a stream of bytes, which each echoes to a separate screen
# region. Since its a char-at-a-time protocol, basic editing characters (kill
# char/word/line) are also sent.
#
# talkd(8) acts as a location service. It listens on UDP port 518
# (specifically, the 'ntalk' known port). A talk(1) client will start by
# sending a packet asking for the location (that is, a IP:port for another
# listening talk(1) client) of a given username/tty on the system.
#
# If there's one waiting, talkd(8) will return its location, and talk(1) will
# proceed to a TCP connect to it. talkd(8) is never involved in the
# conversation again.
#
# If its not found, talk(1) can publish an advertisment into talkd(8), so that
# another talk(1) can find it by the method above.
#
# This channel acts as a minimal talkd(8) and a talk(1) server. It waits for a
# query from talk(1), and in response creates a listening socket and then
# replies with its location. Moments later, when talk(1) connects, it sets up a
# proper session and begins reading text and feeding it into Synergy's core as
# normal event objects.
#
# Because talkd(8) is a "global" (system-wide) service, there can be only one,
# which means this won't really work on a system that has one running. I doubt
# this will ever come up.
#
# To identify yourself to Synergy, instruct talk(1) to talk "to" your username,
# eg 'talk robn@localhost'. The channel will read the requested name, and set
# up your session as that Synergy user. This is your only form of
# "authentication". This would be a problem if you were to expose this channel
# to the internet. Please don't do that.
#
# As noted, talkd(8) is expected to listen on port 518. Since that's a
# privileged port, Synergy has to run as root. Fortunately, both this channel
# and talk(1) honour the 'ntalk' known port in /etc/services, so change it to
# something else (eg 5518) to avoid the need to run it as root.
#
# Good luck!
#
# -- robn, 2021-02-19 


# active sessions, UUID => ::Session object
has _sessions => (
  isa     => 'HashRef',
  traits  => [ 'Hash' ],
  handles => {
    get_session   => 'get',
    track_session => 'set',
    drop_session  => 'delete',
    all_sessions  => 'values',
  },
  default => sub { {} },
);

# protocol utility functions
sub _unpack_request ($dgram) {
  # /*
  #  * Client->server request message format.
  #  */
  # typedef struct {
  #   u_char           vers;       /* protocol version */
  #   u_char           type;       /* request type, see below */
  #   u_char           answer;     /* not used */
  #   u_char           pad;
  #   u_int32_t        id_num;     /* message id */
  #   struct osockaddr addr;       /* old (4.3) style */
  #   struct osockaddr ctl_addr;   /* old (4.3) style */
  #   int32_t          pid;        /* caller's process id */
  #   char             l_name[12]; /* caller's name */
  #   char             r_name[12]; /* callee's name */
  #   char             r_tty[16];  /* callee's tty name */
  # } CTL_MSG;
  #
  # struct osockaddr {
  #   unsigned short int sa_family;
  #   unsigned char sa_data[14];
  # };

  my %req;
  @req{qw(vers type answer pad id_num data_family data_addr ctl_family ctl_addr pid l_name r_name r_tty)} =
    unpack 'C C C C L n a14 n a14 l A12 A12 A16', $dgram;

  return \%req;
}

sub _pack_response ($req, $answer, $addr = '') {
  # /*
  #  * Server->client response message format.
  #  */
  # typedef struct {
  #   u_char           vers;   /* protocol version */
  #   u_char           type;   /* type of request message, see below */
  #   u_char           answer; /* response to request message, see below */
  #   u_char           pad;
  #   u_int32_t        id_num; /* message id */
  #   struct osockaddr addr;   /* address for establishing conversation */
  # } CTL_RESPONSE;

  return pack('C C C C L a16', 1, $req->{type}, $answer, 0, $req->{id_num}, $addr);
}

use constant {
  # message type values
  LEAVE_INVITE => 0,            # leave invitation with server
  LOOK_UP      => 1,            # check for invitation by callee
  DELETE       => 2,            # delete invitation by caller
  ANNOUNCE     => 3,            # announce invitation by caller

  # answer values
  SUCCESS           => 0,       # operation completed properly
  NOT_HERE          => 1,       # callee not logged in
  FAILED            => 2,       # operation failed for unexplained reason
  MACHINE_UNKNOWN   => 3,       # caller's machine name unknown
  PERMISSION_DENIED => 4,       # callee's tty doesn't permit announce
  UNKNOWN_REQUEST   => 5,       # request has invalid type value
  BADVERSION        => 6,       # request has invalid protocol version
  BADADDR           => 7,       # request has invalid addr value
  BADCTLADDR        => 8,       # request has invalid ctl_addr value
};

sub start ($self) {
  my $socket = IO::Async::Socket->new(
    autoflush => 1,
    on_recv => sub ($socket, $dgram, $addr) {

      my $req = _unpack_request($dgram);

      # we are very stupid
      if ($req->{vers} != 1) {
        $socket->send(_pack_response($req, BADVERSION), 0, $addr);
        return;
      }

      # get the requests that we don't care about out of the way early
      if ($req->{type} == LEAVE_INVITE || $req->{type} == DELETE || $req->{type} == ANNOUNCE) {
        $socket->send(_pack_response($req, PERMISSION_DENIED), 0, $addr);
        return;
      }

      # anything else we don't support
      unless ($req->{type} == LOOK_UP) {
        $socket->send(_pack_response($req, UNKNOWN_REQUEST), 0, $addr);
        return;
      }

      my ($ip, $port) = do { my ($p, $a) = unpack_sockaddr_in($addr); (inet_ntoa($a), $p) };
      $Logger->log(['talk: setting up new session for: %s:%s', $ip, $port]);

      # ok, they wanna talk to us, so time to get a listening socket ready to go
      my $listener = IO::Async::Listener->new(
        on_stream => sub ($listener, $stream) {

          # new data connection

          # don't listen anymore
          $listener->remove_from_parent;
          
          # new session!
          my $session = Synergy::Channel::Talk::Session->new(
            username => $req->{r_name},
            stream   => $stream,
          );
          $self->track_session($session->guid, $session);

          my $ip     = $stream->read_handle->peerhost;
          my $port   = $stream->read_handle->peerport;

          $Logger->log(['talk: created session: %s %s', $session->guid, $session->username]);

          $stream->configure(
            on_read => sub ($stream, $bufref, $eof) {
              return 0 if $eof;

              # remote will start by sending three bytes to establish its edit chars
              if (!$session->has_erase_char && length $bufref > 0) {
                $session->erase_char(substr $$bufref, 0, 1, '');
              }
              if (!$session->has_kill_char && length $bufref > 0) {
                $session->kill_char(substr $$bufref, 0, 1, '');
              }
              if (!$session->has_word_erase_char && length $bufref > 0) {
                $session->word_erase_char(substr $$bufref, 0, 1, '');
              }

              return 0 unless length $$bufref;

              # talk(1) sends single characters in real time, but synergy
              # operates on lines, so we have to build a line up as we go, and
              # only once entered submit it to synergy for consideration
              my $line = $session->partial_line;

              while (length $$bufref) {
                # take single character. this is sort of horribly inefficient,
                # but as noted, its very very rare for there to ever be more
                # than one character
                my $c = substr $$bufref, 0, 1, '';

                if ($c eq $session->erase_char) {
                  # backspace; kill the last character
                  substr $line, -1, 1, '';
                }
                elsif ($c eq $session->kill_char) {
                  # kill line; drop the lot
                  $line = '';
                }
                elsif ($c eq $session->word_erase_char) {
                  # erase word; drop everything back to the previous space or start of line
                  $line =~ s/ ?[^ ]+$/ /;
                }
                elsif ($c ne "\n") {
                  # anything else, just append to buffer
                  $line .= $c;
                }
                elsif (length $line) {
                  # newline, but only if there's something in the buffer

                  # user by session name, if there is one
                  my $user = $self->hub->user_directory->user_named($session->username);

                  # simulate private 1:1 chat
                  my $event = Synergy::Event->new({
                    type         => 'message',
                    text         => $line,
                    was_targeted => 1,
                    is_public    => 0,
                    from_channel => $self,
                    from_address => $session->guid,
                    ($user ? (from_user => $user) : ()),
                    conversation_address => $session->guid,
                  });
                  $self->hub->handle_event($event);

                  # line processed
                  $line = '';
                }
              }

              # ran out of stuff from the client, so put the partial line aside for next time
              $session->partial_line($line);

              $$bufref = '';
              return 0;
            },

            on_closed => sub {
              # they went away; clean up
              $Logger->log(['talk: disconnected: %s %s', $session->guid, $session->username]);
              $self->drop_session($session->guid);
              undef $session;
            },
          );

          # send some control chars. these are the "standard" ASCII-ish ones
          # that talk(1) sends. it doesn't matter; we will never send them
          # because synergy does not make mistakes
          $stream->write("\x7f\x15\x17");

          $self->hub->loop->add($stream);
        },
      );

      $self->hub->loop->add($listener);

      $listener->listen(
        addr => {
          family   => 'inet',
          socktype => 'stream',
          ip       => '127.0.0.1',
        },

        on_listen => sub ($listener) {
          my $handle = $listener->read_handle;
          my $family = $handle->sockdomain;
          my $ip     = $handle->sockhost;
          my $port   = $handle->sockport;

          $Logger->log(['talk: offering port for data service: %s:%s', $ip, $port]);

          # sigh. because osockaddr is not a proper sockaddr_in, we need to construct one ourselves
          my $listen_addr = pack 'n n a4 a8', $family, $port, inet_aton($ip), '';

          # send the success packet back with the data port location, so the client can connect
          $socket->send(_pack_response($req, SUCCESS, $listen_addr), 0, $addr);

          # if nothing connects after a short wait, stop listening
          my $timer = IO::Async::Timer::Countdown->new(
            delay => 5,
            on_expire => sub {
              return unless $listener->loop;
              $Logger->log(['talk: timed out, offer withdrawn: %s:%s', $ip, $port]);
              $listener->remove_from_parent;
            }
          );
          $timer->start;
          $self->hub->loop->add($timer);
        },
      )->get;
    },
  );

  $self->hub->loop->add($socket);

  $socket->bind(
    host     => '127.0.0.1',
    service  => 'ntalk',
    socktype => 'dgram',
  )->get;
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  my ($sessions) = grep { $_->username eq $user->username } $self->all_sessions;
  for my $session ($sessions) {
    $self->send_message($self->guid, $text, $alts);
  }
}

sub send_message ($self, $target, $text, $alts) {
  my $session = $self->get_session($target);
  unless ($session) {
    $Logger->log(['talk: send_message: no session for target: %s', $target]);
    return;
  }

  # the talk proto is actually 8-bit clean (the three control chars are just
  # that) but I didn't really want to think about what to do with the emoji and
  # other shenanigans embedded in Synergy's brain. cowardly flattening to ASCII
  # will do for now
  $session->stream->write(unidecode($text) . "\n"); }

sub describe_event ($self, $event) {
  my $username = $event->from_user ? $event->from_user->username : $event->from_address;
  return "a message from $username";
}

sub describe_conversation ($self, $event) {
  my $username = $event->from_user ? $event->from_user->username : $event->from_address;
  return $username;
}


package Synergy::Channel::Talk::Session;

use Moose;
use Data::GUID qw(guid_string);

has username => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has stream => (
  is => 'ro',
  # isa => IO::Async::Stream
  required => 1,
);

has guid => (
  is => 'ro',
  isa => 'Str',
  lazy => 1,
  default => sub { lc guid_string },
);

has erase_char => (
  is => 'rw',
  predicate => 'has_erase_char',
);
has kill_char => (
  is => 'rw',
  predicate => 'has_kill_char',
);
has word_erase_char => (
  is => 'rw',
  predicate => 'has_word_erase_char',
);

has partial_line => (
  is => 'rw',
  clearer => 'clear_partial_line',
  default => '',
);

1;
