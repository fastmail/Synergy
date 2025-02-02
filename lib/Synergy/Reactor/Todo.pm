use v5.36.0;
package Synergy::Reactor::Todo;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use Synergy::CommandPost;

use namespace::clean;

use Data::GUID qw(guid_string);
use DateTime;
use Encode qw( encode );
use Future::AsyncAwait;
use MIME::Base64;
use Synergy::Logger '$Logger';
use Synergy::Util qw(reformat_help);

command todo => {
  help => reformat_help(<<~"EOH"),
    *todo `TITLE`*: add something to your personal todo list

    If the task's title ends with exclamation points (after a space separating
    them from the rest of the title), it indicates the priority of the task.
    One (!) is low, two (!!) is medium, and more than two (like !!!!!!) is
    high.
    EOH
} => async sub ($self, $event, $rest) {
  my $user = $event->from_user;

  return await $event->error_reply("Sorry, I don't know who you are!")
    unless $user;

  return await $event->error_reply("I can't tell you to do nothing!")
    unless length $rest;

  my $password = $self->get_user_preference($user, 'password');
  my $username = $self->get_user_preference($user, 'calendar-user');
  my $calendar = $self->get_user_preference($user, 'calendar-id');

  return await $event->error_reply("You haven't configured your todo calendar")
    unless $password and $username and $calendar;

  my ($summary, $description) = split /\n+/, $rest, 2;

  my $priority;
  if ($summary =~ s/\s+(!+)\z//) {
    my $bangs = $1;
    $priority = length $bangs == 1 ? 9  # LOW
              : length $bangs == 2 ? 5  # MEDIUM
              :                      1; # HIGH
  }

  my ($uid, $ical) = $self->_make_icalendar($summary, {
    (length $description  ? (DESCRIPTION  => $description)  : ()),
    ($priority            ? (PRIORITY     => $priority)     : ()),
  });

  my $uri_username = $username =~ s/@/%40/gr;

  my $res = eval {
    await $self->hub->http_client->do_request(
      method => 'PUT',
      uri    => "https://caldav.fastmail.com/dav/calendars/user/$uri_username/$calendar/$uid.ics",
      content_type => 'text/calendar',
      content      => $ical,
      headers => [
        Authorization => 'Basic ' . encode_base64("$username:$password", ""),
      ],
    );
  };

  if ($@) {
    $Logger->log([ "exception making todo: %s", $@ ]);
    return await $event->reply_error("Sorry, something went really wrong!");
  }

  unless ($res->is_success) {
    $Logger->log([ "todo creation failed: %s", $res->as_string ]);
    return await $event->reply_error("Sorry, something went wrong!");
  }

  return await $event->reply("Todo created!");
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
  describer   => async sub ($self, $value) { defined $value ? '<redacted>' : '<unset>' },
  validator   => async sub ($self, $value, $event) {
    return ($value, undef);
  },
  default     => undef,
);

__PACKAGE__->add_preference(
  name        => 'calendar-user',
  help        => "The calendar user where you store your todos",
  description => "The calendar user where you store your todos",
  describer   => async sub ($self, $value) { $value // '<unset>' },
  validator   => async sub ($self, $value, $event) {
    return ($value, undef);
  },
  default     => undef,
);

__PACKAGE__->add_preference(
  name        => 'calendar-id',
  help        => "The calendar id where you store your todos",
  description => "The calendar id where you store your todos",
  describer   => async sub ($self, $value) { $value // '<unset>' },
  validator   => async sub ($self, $value, $event) {
    return ($value, undef);
  },
  default     => undef,
);

1;
