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

  return $event->error_reply("Sorry, new todo items with line breaks!")
    if $rest =~ /\v/;

  my $password = $self->get_user_preference($user, 'password');
  my $username = $self->get_user_preference($user, 'calendar-user');
  my $calendar = $self->get_user_preference($user, 'calendar-id');

  return $event->error_reply("You haven't configured your todo calendar")
    unless $password and $username and $calendar;

  my ($uid, $ical) = $self->_make_icalendar($rest);

  my $uri_username = $username =~ s/@/%40/gr;

  $self->hub->http_client->do_request(
    method => 'PUT',
    uri    => "https://caldav.fastmail.com/dav/calendars/user/$uri_username/$calendar/$uid.ics",
    content_type => 'text/calendar',
    content      => encode('UTF-8', $ical),
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

sub _make_icalendar ($self, $summary) {
  my $template = <<~'END';
  BEGIN:VCALENDAR
  CALSCALE:GREGORIAN
  PRODID:-//Synergy//Todo
  VERSION:2.0
  BEGIN:VTODO
  CREATED:%s
  DTSTAMP:%s
  STATUS:INCOMPLETE
  SUMMARY:%s
  UID:%s
  END:VTODO
  END:VCALENDAR
  END

  my $now   = DateTime->now(time_zone => 'UTC');
  my $ztime = $now->ymd('') . 'T' . $now->hms('') . 'Z';

  my $uid = guid_string();

  my $vtodo = sprintf $template,
    $ztime,
    $ztime,
    $summary,
    $uid;

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
