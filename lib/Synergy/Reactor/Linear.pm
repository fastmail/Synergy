use v5.24.0;
use warnings;
package Synergy::Reactor::Linear;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Linear::Client;

use utf8;

sub listener_specs {
  return (
    {
      name      => 'new_issue',
      method    => 'handle_new_issue',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ /\A L ( \+\+ | >> ) \s+/x;
      },
    },
  );
}

# XXX This is bananas and should be user OAuth or, *at least*, a user-provided
# bearer token.
has auth_token => (
  is  => 'ro',
  isa => 'Str',
  default => sub { $ENV{LINEAR_AUTH} },
);

has default_team_id => (
  is => 'ro',
  isa => 'Str',
  default => 'c4196244-4381-498b-ae0b-9288fc459cdd', # move to config!!
);

sub handle_new_issue ($self, $event) {
  $event->mark_handled;

  # Probably we should have one of these cached per user…
  my $linear = Linear::Client->new({
    auth_token       => $self->auth_token,
    default_team_id  => $self->default_team_id,
  });

  my $text = $event->text =~ s/\AL//r;

  my $plan_f = $linear->plan_from_input($text);

  # XXX: I do not like our current error-returning scheme. -- rjbs, 2021-12-10
  $plan_f->else(sub ($error) { $event->error_reply("Couldn't make task: $error") })
         ->then(sub ($plan)  { $linear->create_issue($plan) })
         ->then(sub ($query_result) {
          # XXX The query result is stupid and very low-level.  This will
          # change.
          my $id = $query_result->{data}{issueCreate}{issue}{identifier};
           $event->reply(
            sprintf("I made that task, %s.", $id),
            {
              slack => sprintf("I made that task, <%s|%s>.",
                "https://linear.app/fastmail/issue/$id/...",
                $id),
            },
          )
         });
}

1;
