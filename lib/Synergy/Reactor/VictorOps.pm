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
      help_entries => [
        { title => 'maint', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
Conveniences for managing VictorOps "maintenance mode", aka "silence all the
alerts because everything is on fire."

• *maint*: show current maintenance state
• *maint start*: enter maintenance mode. All alerts are now silenced!
• *maint end*, *demaint*, *unmaint*: leave maintenance mode. Alerts are noisy again!
EOH
      ],
    },
    {
      name      => 'maint-start',
      method    => 'handle_maint_start',
      predicate => sub ($self, $e) { $e->was_targeted && $e->text =~ /^maint\s+start\s*$/i },
    },
    {
      name      => 'maint-end',
      method    => 'handle_maint_end',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return 1 if $e->text =~ /^maint\s+end\s*$/i;
        return 1 if $e->text =~ /^unmaint\s*$/i;
        return 1 if $e->text =~ /^demaint\s*$/i;
      },
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

sub handle_maint_start ($self, $event) {
  $event->mark_handled;

  my $f = $self->hub->http_post(
    $self->_vo_api_endpoint('/maintenancemode/start'),
    $self->_vo_api_headers,
    async => 1,
    Content_Type => 'application/json',
    Content      => encode_json( { names => [] } ), # nothing, global mode
  )->then(
    sub ($res) {
      if ($res->code == 409) {
        return $event->reply("VO already in maint!");
      }

      unless ($res->is_success) {
        $Logger->log("VO: post maint failed: ".$res->as_string);
        return $event->reply("I couldn't start maint. Sorry!");
      }

      return $event->reply("🚨 VO now in maint! Good luck!");
    }
  )->else(
    sub (@fails) {
      $Logger->log("VO: handle_maint_start failed: @fails");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    }
  );

  $f->retain;

  return;
}

sub handle_maint_end ($self, $event) {
  $event->mark_handled;

  my $f = $self->hub->http_get(
    $self->_vo_api_endpoint('/maintenancemode'),
    $self->_vo_api_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log("VO: get maintenancemode failed: ".$res->as_string);
        return $event->reply("I couldn't look up the current VO maint state. Sorry!");
      }

      my $data = decode_json($res->content);
      my $maint = $data->{activeInstances} // [];
      unless (@$maint) {
        return $event->reply("VO not in maint right now. Everything is fine maybe!");
      }

      my ($global_maint) = grep { $_->{isGlobal} } @$maint;
      unless ($global_maint) {
        return $event->reply(
          "I couldn't find the VO global maint, but there were other maint modes set. ".
          "This isn't something I know how to deal with. ".
          "You'll need to go and sort it out in the VO web UI.");
      }

      my $instance_id = $global_maint->{instanceId};

      return $self->hub->http_put(
        $self->_vo_api_endpoint("/maintenancemode/$instance_id/end"),
        $self->_vo_api_headers,
        async => 1,
      );
    }
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log("VO: put maintenancemode failed: ".$res->as_string);
        return $event->reply("I couldn't clear the VO maint state. Sorry!");
      }

      return $event->reply("🚨 VO maint cleared. Good job everyone!");
    }
  )->else(
    sub (@fails) {
      $Logger->log("VO: handle_maint_end failed: @fails");
      return $event->reply("Something went wrong while fiddling with VO maint state. Sorry!");
    }
  );

  $f->retain;
}

1;
