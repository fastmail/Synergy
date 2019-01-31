use v5.24.0;
use warnings;
package Synergy::Reactor::Roto;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use JMAP::Tester;
use JSON::MaybeXS;
use Synergy::Logger '$Logger';

sub listener_specs {
  return {
    name      => 'duty',
    method    => 'handle_duty',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^duty$/i },
  };
}

has roto_config_path => (
  is => 'ro',
  required => 1,
);

has roto_config => (
  is   => 'ro',
  lazy => 1,

  default => sub ($self, @) {
    my $fn = $self->roto_config_path;
    open my $fh, '<', $fn or die "can't read $fn: $!";
    my $json = do { local $/; <$fh> };
    JSON::MaybeXS->new->utf8(1)->decode($json);
  }
);

has jmap_client => (
  is   => 'ro',
  lazy => 1,
  default => sub ($self, @) {
    return Synergy::Reactor::Roto::MyJMAPClient->new({
      api_uri  => $self->roto_config->{jmap}{api_uri},
      username => $self->roto_config->{jmap}{username},
      password => $self->roto_config->{jmap}{password},
    });
  },
);

after register_with_hub => sub ($self, @) {
  $self->roto_config; # crash early, crash often -- rjbs, 2019-01-31
};

sub handle_duty ($self, $event) {
  $event->mark_handled;

  my $now = DateTime->now(time_zone => 'UTC');

  my %want_calendar_id = map {; $_->{calendar_id} => 1 }
                         values $self->roto_config->{rotors}->%*;

  my $res = eval {
    my $res = $self->jmap_client->request({
      using       => [ 'urn:ietf:params:jmap:mail' ],
      methodCalls => [
        [
          'CalendarEvent/query' => {
            filter => {
              inCalendars => [ keys %want_calendar_id ],
              before      => $now->ymd . "T00:00:00Z",
              after       => $now->ymd . "T00:00:00Z",
            },
          },
          'a',
        ],
        [
          'CalendarEvent/get' => { '#ids' => {
            resultOf => 'a',
            name => 'CalendarEvent/query',
            path => '/ids',
          } }
        ],
      ]
    });

    $res->assert_successful;
    $res;
  };

  unless ($res) {
    return $event->reply("Sorry, I couldn't get the duty roster.");
  }

  my @events =
    grep {; $want_calendar_id{ $_->{calendarId} } }
    $res->sentence_named('CalendarEvent/get')->as_stripped_pair->[1]{list}->@*;

  my $reply = "Today's duty roster:\n"
            . join qq{\n}, sort map {; $_->{title} } @events;

  $event->reply($reply);
}

package Synergy::Reactor::Roto::MyJMAPClient {
  use Moo;
  use experimental 'signatures';

  extends 'JMAP::Tester';
  has [ qw(username password) ] => (is => 'ro', required => 1);

  use MIME::Base64 ();

  sub _maybe_auth_header ($self, @) {
    my $auth = MIME::Base64::encode_base64(
      join(q{:}, $self->username, $self->password),
      ""
    );
    return("Authorization" => "Basic $auth");
  }

  no Moo;
}

1;
