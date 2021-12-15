use v5.24.0;
use warnings;
package Synergy::Reactor::Linear;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Linear::Client;

use utf8;

sub listener_specs {
  return (
     {
      name      => 'list_teams',
      method    => 'handle_list_teams',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;

        # Silly, but it's a hack. -- rjbs, 2021-12-15
        return unless lc $e->text eq 'lteams';
      },
    },
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

has default_team_id => (
  is => 'ro',
  isa => 'Str',
  default => 'c4196244-4381-498b-ae0b-9288fc459cdd', # move to config!!
);

sub _with_linear_client ($self, $event, $code) {
  my $user = $event->from_user;

  unless ($user) {
    $event->error_reply("Sorry, I don't know who you are.");
  }

  my $token = $self->get_user_preference($user, 'api-token');

  unless ($token) {
    my $rname = $self->name;
    return $event->error_reply("Hmm, you don't have a Linear API token set. Make one, then set your $rname.api-token preference");
  }

  my $linear = Linear::Client->new({
    auth_token       => $token,
    default_team_id  => $self->default_team_id,
  });

  return $code->($linear);
}

sub handle_list_teams ($self, $event) {
  $event->mark_handled;
  $self->_with_linear_client($event, sub ($linear) {
    $linear->teams->then(sub ($teams) {
      my $text = q{};
      for my $team_key (sort keys %$teams) {
        $text .= sprintf "%s — %s\n", uc $team_key, $teams->{$team_key}{name};
      }

      return $event->reply($text);
    });
  });
}

sub handle_new_issue ($self, $event) {
  $event->mark_handled;

  $self->_with_linear_client($event, sub ($linear) {
    my $text = $event->text =~ s/\AL//r;

    my $plan_f = $linear->plan_from_input($text);

    # XXX: I do not like our current error-returning scheme. -- rjbs, 2021-12-10
    $plan_f
      ->else(sub ($error) { $event->error_reply("Couldn't make task: $error") })
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
  });
}

__PACKAGE__->add_preference(
  name      => 'api-token',
  describer => sub ($value) { return defined $value ? "<redacted>" : '<undef>' },
  default   => undef,
  validator => sub ($self, $value, $event) {
    $value =~ s/^\s*|\s*$//g;

    unless ($value =~ /^lin_api/) {
      return (undef, "that doesn't look like a normal API token; check it and try again?");
    }

    return ($value, undef);
  },
);

1;
