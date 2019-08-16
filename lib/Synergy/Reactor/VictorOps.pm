use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::VictorOps;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use JSON::MaybeXS;
use List::Util qw(first);
use DateTimeX::Format::Ago;
use Synergy::Logger '$Logger';

has alert_endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  default => 'https://api.victorops.com/api-public/v1',
);

has api_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub listener_specs {
  return (
    {
      name      => 'alert',
      method    => 'handle_alert',
      exclusive => 1,
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^alert\s+/i },
      help_entries => [
        { title => 'alert', text => "alert TEXT: get help from staff on call" },
      ],
    },
    {
      name      => 'maint-query',
      method    => 'handle_maint_query',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^maint\s*$/i },
    },
  );
}

sub handle_alert ($self, $event) {
  $event->mark_handled;

  my $text = $event->text =~ s{^alert\s+}{}r;

  my $username = $event->from_user->username;

  my $future = $self->hub->http_post(
    $self->alert_endpoint_uri,
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

sub _vo_api_endpoint ($self, $endpoint) {
  return $self->api_endpoint_uri . $endpoint;
}

sub _vo_api_headers ($self) {
  return (
    'X-VO-Api-Id'  => $self->api_id,
    'X-VO-Api-Key' => $self->api_key,
    Accept         => 'application/json',
  );
}

sub handle_maint_query ($self, $event) {
  $event->mark_handled;

  my $f = $self->hub->http_get(
    $self->_vo_api_endpoint('/maintenancemode'),
    $self->_vo_api_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log("VO: get maintenancemode failed: ".$res->as_string);
        return $event->reply("I couldn't look up VO maint state. Sorry!");
      }

      my $data = decode_json($res->content);
      my $maint = $data->{activeInstances} // [];
      unless (@$maint) {
        return $event->reply("VO not in maint right now. Everything is fine maybe!");
      }

      state $ago_formatter = DateTimeX::Format::Ago->new(language => 'en');

      # the way we use VO there's probably not more than one, but at least this
      # way if there are we won't just drop the rest on the floor -- robn, 2019-08-16 
      my $maint_text = join ', ', map {
        my $start = DateTime->from_epoch(epoch => int($_->{startedAt} / 1000));
        my $ago = $ago_formatter->format_datetime($start);
        "$ago by $_->{startedBy}"
      } @$maint;

      return $event->reply("🚨 VO in maint: $maint_text");
    }
  )->else(
    sub (@fails) {
      $Logger->log("VO: handle_maint_query failed: @fails");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    }
  );

  $f->retain;
}

1;
