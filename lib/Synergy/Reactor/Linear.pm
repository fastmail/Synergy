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

use Synergy::Logger '$Logger';

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
        return unless $e->text =~ /\A L ( \+\+ | >> ) \s+/x; # temporary L
      },
    },
    {
      name      => 'support_blockers',
      method    => 'handle_support_blockers',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text eq 'Lsb'; # XXX temporary
      },
    },
    {
      name      => 'ptn_blocked',
      method    => 'handle_ptn_blocked',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ m{\Aptn\s*([0-9]+) blocked:}i;
      },
    },
    {
      name      => 'support_triage',
      method    => 'handle_triage',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text =~ /\ALtriage(\s|$)/; # XXX temporary
      },
    },
    {
      name      => 'urgent',
      method    => 'handle_urgent',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text eq 'Lurgent'; # XXX temporary
      },
    },
  );
}

package Synergy::Reactor::Linear::LinearHelper {
  use Synergy::Logger '$Logger';

  sub new_for_reactor ($class, $reactor) {
    bless { reactor => $reactor }, $class;
  }

  sub normalize_username ($self, $username) {
    # Really we *probably* shouldn't pass in undef for resolving user, but
    # look, this is all a bit of a bodge at the moment. -- rjbs, 2021-12-20
    $Logger->log("doing username normalization for $username");
    my $user = $self->{reactor}->resolve_name($username, undef);
    return unless $user;
    return $user->username;
  }

  sub team_id_for_username ($self, $username) {
    $Logger->log("doing team lookup for $username");
    my $team_id = $self->{reactor}
                       ->get_user_preference($username, 'default-team');
    return $team_id;
  }
}

has _linear_shared_cache => (
  is => 'ro',
  default => sub {  {}  },
);

sub _with_linear_client ($self, $event, $code) {
  my $user = $event->from_user;

  unless ($user) {
    return $event->error_reply("Sorry, I don't know who you are.");
  }

  my $token = $self->get_user_preference($user, 'api-token');

  unless ($token) {
    my $rname = $self->name;
    return $event->error_reply("Hmm, you don't have a Linear API token set. Make one, then set your $rname.api-token preference");
  }

  my $linear = Linear::Client->new({
    auth_token      => $token,
    _cache_guts     => $self->_linear_shared_cache,
    debug_flogger   => $Logger,

    helper => Synergy::Reactor::Linear::LinearHelper->new_for_reactor($self),
  });

  return $code->($linear);
}

sub handle_list_teams ($self, $event) {
  $event->mark_handled;
  $self->_with_linear_client($event, sub ($linear) {
    $linear->teams->then(sub ($teams) {
      my $text  = qq{Teams in Linear\n};
      my $slack = qq{*Teams in Linear*\n};
      for my $team_key (sort keys %$teams) {
        my $this = sprintf "%s — %s\n", uc $team_key, $teams->{$team_key}{name};
        $text  .= $this;
        $slack .= $this;
      }

      return $event->reply($text, { slack => $slack });
    });
  });
}

sub _handle_search_urgent ($self, $event, $search, $zero, $header, $linear = undef) {
  $event->mark_handled;

  my $code = sub ($linear) {
    my $user = $linear->get_authenticated_user;
    $user->then(sub ($user) {
      $linear->search_issues($search)->then(sub ($result) {
        unless ($result->{data}{issues}{nodes}->@*) {
          return $event->reply($zero);
        }

        my $text  = q{};
        my $slack = q{};

        for my $node ($result->{data}{issues}{nodes}->@*) {
          $text  .= "$node->{identifier} - $node->{title}\n";
          $slack .= sprintf "<%s|%s> - %s\n",
            "https://linear.app/fastmail/issue/$node->{identifier}/...",
            $node->{identifier},
            $node->{title};
        }

        chomp $text;
        chomp $slack;

        return $event->reply(
          "$header:\n$text",
          { slack => "*$header:*\n$slack" },
        );
      });
    });
  };

  if ($linear) {
    return $code->($linear);
  }

  return $self->_with_linear_client($event, $code);
}

sub handle_urgent ($self, $event) {
  $self->_with_linear_client($event, sub ($linear) {
    $linear->get_authenticated_user->then(sub ($user) {
      $self->_handle_search_urgent(
        $event,
        {
          # Total bodge.  We want to use authenticated user id, but the plumbing is
          # wrong. -- rjbs, 2021-12-20
          # assignee => $user->{id},
          assignee => $user->{id},
          priority => 1,
          closed   => 0,
        },
        "There's nothing urgent, so take it easy!",
        "Urgent issues for you",
        $linear,
      );
    });
  });
}

sub handle_support_blockers ($self, $event) {
  $self->_handle_search_urgent(
    $event,
    {
      label   => 'support blocker',
      closed  => 0,
    },
    "No support blockers!  Great!",
    "Current support blockers",
  );
}

sub handle_triage ($self, $event) {
  $event->mark_handled;

  my (undef, $team_name) = split /\s/, $event->text, 2;

  $self->_with_linear_client($event, sub ($linear) {
    my $when  = length $team_name
              ? $linear->lookup_team($team_name)->then(sub ($team) {
                  return Future->fail("no such team") unless $team;
                  return Future->done(team => $team->{id});
                })
              : Future->done;

    $when->then(sub {
      my (%extra_search) = @_;
      $self->_handle_search_urgent(
        $event,
        {
          state    => 'Triage',
          assignee => undef,
          %extra_search,
        },
        "No unassigned tasks in triage!  Great!",
        "Current unassigned triage work",
        $linear,
      );
    })->else(sub {
      $event->error_reply("I couldn't find the team you asked about!");
    });
  });
}

sub _handle_creation_event ($self, $event, $arg = {}) {
  $event->mark_handled;

  my $plan_munger = $arg->{plan_munger};
  my $linear      = $arg->{linear};
  my $ersatz_text = $arg->{ersatz_text};

  my $code = sub ($linear) {
    my $text = $event->text =~ s/\AL//r;

    my $plan_f = $linear->plan_from_input($ersatz_text // $text);

    # XXX: I do not like our current error-returning scheme. -- rjbs, 2021-12-10
    $plan_f
      ->then(sub ($plan) {
        $plan_munger->($plan) if $plan_munger;
        $linear->create_issue($plan);
      })
      ->then(sub ($query_result) {
        # XXX The query result is stupid and very low-level.  This will
        # change.
        my $id = $query_result->{data}{issueCreate}{issue}{identifier};
        if ($id) {
          return $event->reply(
            sprintf("I made that task, %s.", $id),
            {
              slack => sprintf("I made that task, <%s|%s>.",
                "https://linear.app/fastmail/issue/$id/...",
                $id),
            },
          );
        } else {
          return $event->error_reply(
            "Sorry, something went wrong and I can't say what!"
          );
        }
      })
      ->else(sub ($error) { $event->error_reply("Couldn't make task: $error") });
  };

  if ($linear) {
    return $code->($linear);
  }

  $self->_with_linear_client($event, $code);
}

sub handle_new_issue ($self, $event) {
  $self->_handle_creation_event($self, $event);
}

sub handle_ptn_blocked ($self, $event) {
  $event->mark_handled;
  my ($ptn, $rest) = $event->text =~ m{\Aptn\s*([0-9]+) blocked:\s*(.+)}is;
  my $new_text = ">> plumb $2";

  $self->_with_linear_client($event, sub ($linear) {
    my $label_f = $linear->lookup_label("support blocker");
    $label_f->then(sub ($label_id) {
      return $self->_handle_creation_event(
        $event,
        {
          plan_munger => sub ($plan) {
            $plan->{labelIds} = [ $label_id ];

            my $orig = $plan->{description} // q{};
            my $stub = "This issue created from support ticket PTN $ptn.";
            $plan->{description} = length $orig ? "$stub\n\n$orig" : $stub;
            return;
          },
          ersatz_text => $new_text,
        },
      );
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

__PACKAGE__->add_preference(
  name        => 'default-team',
  help        => "Default team in Linear. Make sure to enter the three letter team key.",
  description => "Default team for your Linear tasks",
  describer   => sub ($value) {
    return $value;
  },
  validator   => sub ($self, $value, $event) {
    $self->_with_linear_client($event, sub ($linear) {
      my $team_obj = $linear->lookup_team(lc $value)->get;
      return (undef, "can't find team for $value") unless $team_obj;
      my $team_id = $team_obj->{id};
      return ($team_id);
    })
  },
  default     => undef,
);

1;
