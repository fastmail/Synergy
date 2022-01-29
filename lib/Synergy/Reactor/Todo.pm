use v5.28.0;
use warnings;
package Synergy::Reactor::Todo;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use Synergy::CommandPost;

use experimental qw(signatures);
use namespace::clean;

use Data::GUID qw(guid_string);
use DateTime;
use Encode qw( encode );
use MIME::Base64;
use Synergy::Logger '$Logger';

command todo => {
} => sub ($self, $event, $rest) {
  my $user = $event->from_user;

  return $event->error_reply("Sorry, I don't know who you are!")
    unless $user;

  return $event->error_reply("I can't tell you to do nothing!")
    unless length $rest;

  my $password = $self->get_user_preference($user, 'password');
  my $username = $self->get_user_preference($user, 'calendar-user');
  my $calendar = $self->get_user_preference($user, 'calendar-id');

  return $event->error_reply("You haven't configured your todo calendar")
    unless $password and $username and $calendar;

  my ($summary, $description) = split /\n+/, $rest, 2;

  my $priority;
  if ($summary =~ s/\s+(!+)\z//) {
    my $bangs = $1;
    $priority = length $bangs == 1 ? 1
              : length $bangs == 2 ? 5
              :                      9;
  }

  my ($uid, $ical) = $self->_make_icalendar($summary, {
    (length $description  ? (DESCRIPTION  => $description)  : ()),
    ($priority            ? (PRIORITY     => $priority)     : ()),
  });

  my $uri_username = $username =~ s/@/%40/gr;

  $self->hub->http_client->do_request(
    method => 'PUT',
    uri    => "https://caldav.fastmail.com/dav/calendars/user/$uri_username/$calendar/$uid.ics",
    content_type => 'text/calendar',
    content      => $ical,
    headers => [
      Authorization => 'Basic ' . encode_base64("$username:$password", ""),
    ],
  )->then(sub ($res) {
    if ($res->is_success) {
      return $event->reply("Todo created!");
    } else {
      $Logger->log([ "todo creation failed: %s", $res->as_string ]);
      return $event->reply_error("Sorry, something went wrong!");
    }
  });
};

# SUMMARY is the one-line summary.
#
# DESCRIPTION is the multi-line (maybe) description.
#   When Apple puts a line break into the DESCRIPTION, they use U+02028 - LINE
#   SEPARATOR, and that seems good to me.
#
#   Long lines SHOULD be wrapped to be no longer than 75b.  The spec says you
#   can split between "characters", but I bet in practice it means codepoints,
#   but who can say?  It's just not a great spec.
#
# DUE is when the task is meant to be done by.  If it's not done by this time,
#   it's overdue.
# DTSTART is the date/time of the "start" of the task.  You don't actually need
#   a DTSTART.  If you don't have a DTSTART, the task is associated with each
#   successive day until it's done.  What are the implications of this?
#   Honestly, I can't tell.  The important things seem to be...
#
#   * DUE and DTSTART, if both given, must have the same type.
#   * DUE must be at or later than DTSTART.
#   * DTSTART is the first occurrence of a repeating task.
#
# STATUS is, well, the status of the event.  It can be:
#   * NEEDS-ACTION  - open
#   * COMPLETED     - done
#   * CANCELLED     - not supported by Apple
#   * IN-PROCESS    - not supported by Apple
#
# ALARMS are ... a whole thing.
#
# PRIORITY
#   high    = 1
#   medium  = 5
#   low     = 9
#
# URL is supported by Fantastical but not Apple, so what's the point?

sub _make_icalendar ($self, $summary, $arg = {}) {
  my $before = <<~'END';
  BEGIN:VCALENDAR
  CALSCALE:GREGORIAN
  PRODID:-//Synergy//Todo
  VERSION:2.0
  BEGIN:VTODO
  STATUS:NEEDS-ACTION
  UID:%s
  CREATED:%s
  DTSTAMP:%s
  END

  my $after = <<~'END';
  END:VTODO
  END:VCALENDAR
  END

  my $now   = DateTime->now(time_zone => 'UTC');
  my $ztime = $now->ymd('') . 'T' . $now->hms('') . 'Z';

  my $uid = guid_string();

  my sub foldencode ($name, $value_str) {
    my $value_buf = Encode::encode('UTF-8', $value_str);
    my $line = "$name:$value_buf";
    my @hunks = $line =~ /(.{1,70})/g;
    return(join(qq{\n }, @hunks) . "\n");
  }

  Carp::confess("vertical whitespace in summary") if $summary =~ /\v/;

  my $extra = foldencode(SUMMARY => $summary);
  for my $key (keys %$arg) {
    my $value = $arg->{$key};
    $value =~ s/\v/\N{LINE SEPARATOR}/g;
    $extra .= foldencode($key=> $value);
  }

  my $vtodo = sprintf($before, $uid, $ztime, $ztime)
            . $extra
            . $after;

  return ($uid, $vtodo);
}

__PACKAGE__->add_preference(
  name        => 'password',
  help        => "The password to use in accessing your todo list",
  description => "The password to use in accessing your todo list",
  describer   => sub ($value) { defined $value ? '<redacted>' : '<unset>' },
  validator   => sub ($self, $value, $event) {
    return ($value, undef);
  },
  default     => undef,
);

__PACKAGE__->add_preference(
  name        => 'calendar-user',
  help        => "The calendar user where you store your todos",
  description => "The calendar user where you store your todos",
  describer   => sub ($value) { $value // '<unset>' },
  validator   => sub ($self, $value, $event) {
    return ($value, undef);
  },
  default     => undef,
);

__PACKAGE__->add_preference(
  name        => 'calendar-id',
  help        => "The calendar id where you store your todos",
  description => "The calendar id where you store your todos",
  describer   => sub ($value) { $value // '<unset>' },
  validator   => sub ($self, $value, $event) {
    return ($value, undef);
  },
  default     => undef,
);

1;
