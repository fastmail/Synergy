use v5.24.0;
package Synergy::Reactor::Page;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

has twilio_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub listener_specs {
  return {
    name      => 'page',
    method    => 'handle_page',
    exclusive => 1,
    predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^page/i },
  };
}

sub start ($self) {
  my $name = $self->twilio_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no twilio channel ($name) configured, cowardly giving up")
    unless $channel;
}

sub handle_page ($self, $event, $rch) {
  my ($who, $what) = $event->text =~ m/^page\s+([a-z]+):\s+(.*)/i;

  my $user = $self->hub->user_directory->user_by_name($who);

  unless ($user) {
    $rch->reply("I don't know who '$who' is. Sorry :confused:");
    return;
  }

  unless ($user->has_phone) {
    $rch->reply("'$who' doesn't have a phone number. :confused:");
    return;
  }

  my $twilio = $self->hub->channel_named($self->twilio_channel_name);

  my $from = $event->from_user ? $event->from_user->username
                               : $event->from_address;

  my $res = $twilio->send_message_to_user("$from says: $what");
  my $str = ($res && $res->is_success) ? "page sent!"
                                       : "Oops...something went wrong.";
  $rch->reply($str);
  return 1;
}

1;
