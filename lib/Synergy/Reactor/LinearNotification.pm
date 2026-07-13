use v5.36.0;
use utf8;
package Synergy::Reactor::LinearNotification;

use Moose;
with 'Synergy::Role::Reactor', 'Synergy::Role::HTTPEndpoint';

use namespace::clean;
use Synergy::Logger '$Logger';

use JSON::MaybeXS qw(encode_json decode_json);
use Try::Tiny;
use Synergy::Reactor::Linear;

# Because we're a generic Reactor and not EasyListening or CommandPost:
sub potential_reactions_to {}

my $ESCALATION_EMOJI = "\N{HELMET WITH WHITE CROSS}";

has '+http_path' => (
  default => '/linear-notification',
);

has escalation_label_name => (
  is => 'ro',
  isa => 'Str',
  default => 'support blocker',
);

# Synergy channel, like 'slack' or w/e it's called in config
has escalation_channel_name => (
  is  => 'ro',
  isa => 'Str',
);

# The slack address of the channel to send notificaitons to
has escalation_address => (
  is  => 'ro',
  isa => 'Str',
);

sub _rototron ($self) {
  # TODO: indirection through rototron_reactor name on object
  return unless my $roto_reactor = $self->hub->reactor_named('rototron');
  return $roto_reactor->rototron;
}

my %allowed = (
  '35.231.147.226' => 1,
  '35.243.134.228' => 1,
);

has confirm_remote_ips => (
  is => 'ro',
  isa => 'Bool',
  default => 1,
);

has linear_token => (
  is => 'ro',
  required => 1,
);

has linear => (
  is => 'ro',
  isa => 'Linear::Client',
  default => sub ($self) {
    Linear::Client->new({
      auth_token      => $self->linear_token,
      debug_flogger   => $Logger,

      helper => Synergy::Reactor::Linear::LinearHelper->new_for_reactor($self),
    });
  },
  lazy => 1,
);

has name => (
  is => 'ro',
  default => 'lin',
);

has zendesk => (
  is => 'ro',
  isa => 'Zendesk::Client',
  default => sub ($self) {
    return Synergy::Reactor::Zendesk->zendesk_client;
  },
  lazy => 1,
);

sub linear_update_zendesk ($payload) {
  my $issue_id = $payload->{data}{issueId};
  my $issue = $self->linear->do_query(
    q[ query Issue {
      issue(id: $issue_id) {
        attachments { nodes { url } }
        labels { nodes { name } }
      }
    }])->get;

  my $has_escalation_label = grep {
    lc $_{name} eq lc $self->escalation_label_name
  } $issue->{data}{issue}{labels}{nodes}->@*;

  my @zendesk_url = grep {
    $_{url} =~ /.*fastmail\.help\/agent\/tickets\/\d*/
  } $issue->{data}{issue}{attachments}{nodes}->@*;

  if ($has_escalation_label && @zendesk_url) {
    $zendesk_url[0] =~ /.*\/(\d*)/;

    $self->zendesk->ticket_api->add_comment_to_ticket_f($1, {
        body => "Issue updated with a comment: $payload->{url}",
        public => \0,
      })->else(sub ($err, @) {
        $Logger->log([ "something went wrong posting to Zendesk: %s", $err ]);
        return Future->done;
      })->retain;

    $self->zendesk->ticket_api->update_by_zendesk_id_f($1, {
        status => "open",
      })->else(sub ($err, @) {
        $Logger->log([ "something went wrong changing the zendesk ticket status: %s", $err ]);
        return Future->done;
      })->retain;
  }
}

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

  if ($self->confirm_remote_ips) {
    unless ($allowed{$req->address}) {
      $Logger->log([
        "rejecting LinearNotification request from unknown IP %s",
        $req->address,
      ]);

      return [ "200", [], [ '{"go":"away"}' ] ];
    }
  }

  my $err;

  my $payload = try {
    decode_json( $req->raw_body );
  } catch {
    $err = $_;
  };

  if ($err) {
    $Logger->log("LinearNotification failed to parse json: $err");

    return [ "200", [], [ '{"bad":"json"}' ] ];
  }

  # Notify in slack if issue is escalated
  if ($self->escalation_channel_name && $self->escalation_address) {
    if (my $channel = $self->hub->channel_named($self->escalation_channel_name)) {

      my $was_create = $payload->{type} eq 'Issue'
                    && $payload->{action} eq 'create'
                    && grep {
                         lc $_->{name} eq lc $self->escalation_label_name
                       } $payload->{data}->{labels}->@*;

      my $was_update;

      if (   ! $was_create
          && $payload->{type} eq 'Issue'
          && $payload->{action} eq 'update'
      ) {
        # Did we add the escalation label to an existing task?
        my ($label) = grep {
          lc $_->{name} eq lc $self->escalation_label_name
        } $payload->{data}->{labels}->@*;

        if ($label) {
          my $id = $label->{id};
          if (   $payload->{updatedFrom}{labelIds}
              && ! grep { $_ eq $id } $payload->{updatedFrom}{labelIds}->@*
          ) {
            $was_update = 1;
          }
        }
      }

      if ($was_create || $was_update) {
        $self->linear->users->then(sub ($users) {
          my %by_id = map { $users->{$_}->{id} => $users->{$_} } keys %$users;

          return Future->done($by_id{$payload->{data}->{creatorId}}->{displayName} // 'unknown');
        })->then(sub ($who) {
          my $desc = $was_create ? 'New task created for' : 'Existing task moved to';
          my $app = $was_create ? 'Zendesk' : 'Linear';
          $who = 'someone' unless $was_create;

          my $base_text = sprintf
            "%s %s escalation by %s in %s: %s",
            $ESCALATION_EMOJI,
            $desc,
            $who,
            $app,
            $payload->{data}{title};

          my ($identifier) = $payload->{url} =~ m{/linear\.app/fastmail/issue/([A-Z]+-[0-9]+)/};
          $identifier //= $payload->{url};
          my $text  = "$base_text ($payload->{url})";
          my $slack = "$base_text (<$payload->{url}|$identifier>)";

          if (my $rototron = $self->_rototron) {
            my $roto_reactor = $self->hub->reactor_named('rototron');

            for my $officer ($roto_reactor->current_triage_officers) {
              $Logger->log(["notifying %s of new escalation task", $officer->username ]);
              $channel->send_message_to_user($officer, $text, { slack => $slack });
            }
          }

          return $channel->send_message($self->escalation_address, $text, { slack => $slack });
        })->catch(sub {
          $Logger->log("failed to tell escalation about a ticket create in linear: @_");

          return $channel->send_message($self->escalation_address, "Uh, failed to tell you about a ticket create (@_)");
        })->retain;
      }
    }
  }

  # Action Zendesk ticket if comments are made on linear issues
  my $made_comment = $payload->{type} eq 'Issue comments'
                      && $payload->{action} eq 'create';

  if ($made_comment) {
    linear_update_zendesk($payload);
  }

  return [ "200", [], [ '{"o":"k"}' ] ];
}

1;
