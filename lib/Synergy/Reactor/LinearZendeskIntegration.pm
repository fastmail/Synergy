use v.5.28.0;
use warnings;
package Synergy::Reactor::LinearZendeskIntegration;

use Moose;

with 'Synergy::Role::Reactor::EasyListening';
with 'Synergy::Role::HTTPEndpoint';

use Synergy::Reactor::Linear;
use Synergy::Reactor::Zendesk;
use Synergy::Logger '$Logger';
use experimental qw(signatures postderef);

has +http_path => (
  default => '/linearzendeskintegration',
);

has escalation_label_name => (
  is => 'ro',
  isa => 'Str',
  default => 'support blocker',
);

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
        auth_token => $self->linear_token,
        helper     => Synergy::Reactor::Linear::LinearHelper->new_for_reactor($self),
      });
  },
  lazy => 1,
);

has zendesk => (
  is => 'ro',
  isa => 'Zendesk::Client',
  default => sub ($self) {
    return Synergy::Reactor::Zendesk->zendesk_client;
  },
  lazy => 1,
);

sub http_app ($self, $env) {
  my $req = Plack::Request->new($env);

  if ($self->confirm_remote_ips) {
    unless ($allowed{$req->address}) {
      warn "ADDRESS " . $req->address . " not allowed\n";
      return [ "200", [], ['{"go":"away"}'] ];
    }
  }
  
  my $err;

  my $payload = try {
    decode_json( $req->raw_body );
  } catch {
    $err = $_;
  };

  if ($err) {
    warn "Failed to parse json: $err\n";

    return [ "200", [], [ '{"bad":"json"}' ] ];
  }

  my $made_comment = $payload->{type} eq 'Issue comments'
                      && $payload->{action} eq 'create';
  
  if ($made_comment) {
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
  return [ "200", [], [ '{"o":"k"}' ] ];
}

sub listener_specs {
  return {
    name      => 'linear_zendesk_notification',
    method    => 'linear_zendesk_notification',
    predicate => sub ($, $e) { 0 },
  };
}

no Moose;
1;
