use v5.24.0;
use warnings;
package Synergy::Reactor::VictorOps;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use JSON::MaybeXS;
use List::Util qw(first);

has endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub listener_specs {
  return {
    name      => 'alert',
    method    => 'handle_alert',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^alert\s+/i },
    help_entries => [
      { title => 'alert', text => "alert TEXT: get help from staff on call" },
    ],
  };
}

sub handle_alert ($self, $event) {
  $event->mark_handled;

  my $text = $event->text =~ s{^alert\s+}{}r;

  my $username = $event->from_user->username;

  my $future = $self->hub->http_post(
    $self->endpoint_uri,
    async => 1,
    Content_Type  => 'application/json',
    Content       => encode_json({
      message_type  => 'CRITICAL',
      entity_id     => "synergy.via-$username",
      entity_display_name => "$text",
      state_start_time    => time,

      state_message => "$username has requested assistance through Synergy:\n$text\n",
    }),
  );

  $future->on_fail(sub {
    $event->reply("I couldn't send this alert.  Sorry!");
  });

  $future->on_ready(sub {
    $event->reply("I've sent the alert.  Good luck!");
  });

  return;
}

1;
