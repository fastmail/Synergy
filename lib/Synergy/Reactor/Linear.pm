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
      targeted  => 1,
      predicate => sub ($, $e) {
        # Silly, but it's a hack. -- rjbs, 2021-12-15
        return unless lc $e->text eq 'linear teams';
      },
      help_entries => [
        { title => 'task', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*linear teams*: list all the teams in Linear
EOH
      ]
    },
    {
      name      => 'new_issue',
      method    => 'handle_new_issue',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\A ( \+\+ | >> ) \s+/x; },
      help_entries => [
        { title => '++', text => 'This is like using `>>` but supplying yourself as the target.  See *help >>* instead.' },
        { title => '>>', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*>> `TARGET` `NAME`*: create a new issue in Linear

In the simplest form, this creates a new task with the given name, assigned to
the given target.  (More on "targets" below.)  Any text after a line break or
after triple dashes (`---`) becomes part of the long form description of the
task, using Markdown.

The `TARGET` can be either:
• a username
• a team name
• username@team

If only a username is given, the issue is assigned to that user in their
default team.  If only a team name is given, the issue is created unassigned in
that team.  If both are given, the issue is created in the given team and
assigned to the given user.
EOH
      ]
    },
    {
      name      => 'support_blockers',
      method    => 'handle_support_blockers',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text eq 'sb'; },
      help_entries => [
        { title => 'sb', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*sb*: list unassigned support-blocking issues in Linear

This will list all open, unassigned issues in Linear tagged "support blocker".
EOH
      ]
    },
    {
      name      => 'ptn_blocked',
      method    => 'handle_ptn_blocked',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ m{\Aptn\s*([0-9]+) blocked:}i; },
      help_entries => [
        { title => 'ptn blocked', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*ptn `NUMBER` blocked: `DESC`*: create a new support-blocking Linear issue

This command will create a new issue in Linear, much like `>>`.  It assigns the
issue to plumbing and tags it *support blocker*.  The `DESC` is what you'd put
after `>> plumbing` if you were using `>>`.

*In general, don't use this!*  Instead, use the Zendesk integration.
EOH
      ]
    },
    {
      name      => 'support_triage',
      method    => 'handle_triage',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Atriage(\s|$)/; },
      help_entries => [
        { title => 'triage', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*triage `[TEAM]`*: list unassigned issues in the Triage state

This lists (the first page of) all unassigned issues in the Triage state in
Linear.  You can supply an argument, the name of a team, to see only issues for
that team.
EOH
      ],
    },
    {
      name      => 'urgent',
      method    => 'handle_urgent',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text eq 'urgent'; },
      help_entries => [
        { title => 'urgent', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*urgent*: list urgent issues assigned to you
EOH
      ],
    },
    {
      name      => 'agenda',
      method    => 'handle_agenda',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /\Aagenda(\s|$)/; },
      help_entries => [
        { title => 'agenda', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
*agenda `[TARGET]`*: list issues in the To Discuss state

This command lists issues in the state To Discuss.  If a target is given
(either a user name, a team name, or user@team), only issues with that
assignment are listed.
EOH
      ]
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

  sub normalize_team_name ($self, $team_name) {
    return $self->{reactor}->canonical_team_name_for($team_name);
  }

  sub team_id_for_username ($self, $username) {
    $Logger->log("doing team lookup for $username");
    my $team_id = $self->{reactor}
                       ->get_user_preference($username, 'default-team');
    return $team_id;
  }
}

has team_aliases => (
  traits  => [ 'Hash' ],
  default => sub {  {}  },
  handles => {
    canonical_team_name_for => 'get',
  },
);

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

sub _handle_search ($self, $event, $search, $zero, $header, $linear = undef) {
  $event->mark_handled;

  my $code = sub ($linear) {
    my $user = $linear->get_authenticated_user;
    $user->then(sub ($user) {
      $linear->search_issues($search)->then(sub ($page) {
        unless ($page->payload->{nodes}->@*) {
          return $event->reply($zero);
        }

        my $text  = q{};
        my $slack = q{};

        for my $node ($page->payload->{nodes}->@*) {
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
  $event->mark_handled;

  $self->_with_linear_client($event, sub ($linear) {
    $linear->get_authenticated_user->then(sub ($user) {
      $self->_handle_search(
        $event,
        {
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
  $event->mark_handled;

  $self->_handle_search(
    $event,
    {
      label     => 'support blocker',
      closed    => 0,
      assignee  => undef,
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
      $self->_handle_search(
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

sub handle_agenda ($self, $event) {
  $event->mark_handled;

  my (undef, $spec) = split /\s/, $event->text, 2;

  $self->_with_linear_client($event, sub ($linear) {
    my $when  = length $spec
              ? $linear->who_or_what($spec)->then(sub ($assignee_id, $team_id) {
                  return Future->fail("no such team") unless $team_id;

                  if ($spec =~ /@/) {
                    return Future->done(assignee => $assignee_id, team => $team_id);
                  } else {
                    # Okay they said 'agenda foo'. Foo could be a team or a user.
                    # If it's a user, they want all agenda items for that user, so
                    # we need to ignore the team.
                    if ($assignee_id) {
                      return Future->done(assignee => $assignee_id);
                    } else {
                      return Future->done(team => $team_id);
                    }
                  }
                })
              : $linear->get_authenticated_user->then(sub ($user) {
                  return Future->done(assignee => $user->{id});
                });

    $when->then(sub {
      my (%extra_search) = @_;
      $self->_handle_search(
        $event,
        {
          state    => 'To Discuss',
          %extra_search,
        },
        "You have nothing on the agenda",
        "Current agenda",
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
    my $text = $event->text;

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
        my $id  = $query_result->{data}{issueCreate}{issue}{identifier};
        my $url = $query_result->{data}{issueCreate}{issue}{url};
        if ($id) {
          return $event->reply(
            sprintf("I made that task, %s: %s", $id, $url),
            {
              slack => sprintf("I made that task, <%s|%s>.", $url, $id),
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
  if ($event->text =~ /\AL?>> triage /i) {
    $event->mark_handled;
    return $event->error_reply(q{You can't assign directly to triage anymore.  Instead, use the Zendesk integration!  You can also look at help for "ptn blocked".});
  }

  $self->_handle_creation_event($event);
}

sub handle_ptn_blocked ($self, $event) {
  $event->mark_handled;
  my ($ptn, $rest) = $event->text =~ m{\Aptn\s*([0-9]+) blocked:\s*(.+)}is;
  my $new_text = ">> plumb $2";

  $self->_with_linear_client($event, sub ($linear) {
    my $label_f = $linear->lookup_team_label("plumb", "support blocker");
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

    if ($event->is_public) {
      return (undef, "You shouldn't try to set an API token in public.  You should probably revoke that token in Linear, make a new one, and set it in a private message next time.");
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
    # Look, this is *terrible*.  _with_linear_client will return a reply
    # future, if we failed.  Otherwise it returns the result of the called sub,
    # which here is the expected (ok, error) tuple.  We need to detect the
    # failure case of _with_linear_client and turn it a pref-setting failure.
    # -- rjbs, 2021-12-21
    my ($ok, $error) = $self->_with_linear_client($event, sub ($linear) {
      my $team_obj = $linear->lookup_team(lc $value)->get;
      return (undef, "can't find team for $value") unless $team_obj;
      my $team_id = $team_obj->{id};
      return ($team_id);
    });

    if ($ok && ref $ok) {
      # This is the weirdly bad case.
      return (undef, "can't set your team until you configure your API token");
    }

    return ($ok, $error);
  },
  default     => undef,
);

1;
