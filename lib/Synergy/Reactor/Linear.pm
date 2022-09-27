use v5.28.0;
use warnings;
package Synergy::Reactor::Linear;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor',
     'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::DeduplicatesExpandos' => {
       expandos => [ 'issue' ],
     };

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Linear::Client;
use Lingua::EN::Inflect qw(PL_N);

use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(bool_from_text reformat_help);

use utf8;

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
    return $self->{reactor}->canonical_team_name_for(lc $team_name);
  }

  sub team_id_for_username ($self, $username) {
    $Logger->log("doing team lookup for $username");
    my $team_id = $self->{reactor}
                       ->get_user_preference($username, 'default-team');
    return $team_id;
  }
}

has team_aliases => (
  reader  => '_team_aliases',
  default => sub {  {}  },
  traits  => [ 'Hash' ],
  handles => {
    known_team_keys  => 'keys',
  }
);

has _name_mappings => (
  init_arg => undef,
  lazy     => 1,
  traits   => [ 'Hash' ],
  handles  => {
    canonical_team_name_for => 'get',
  },
  default  => sub ($self) {
    my $names = $self->_team_aliases;

    my %mapping;
    for my $team (keys %$names) {
      for ($team, $names->{$team}->@*) {
        Carp::confess("Attempted to give two names for $_")
          if exists $mapping{$_};

        $mapping{$_} = $team;
      }
    }

    return \%mapping;
  }
);

has _linear_shared_cache => (
  is => 'ro',
  default => sub {  {}  },
);

sub _linear_client_for_user ($self, $user) {
  # This is a bit of duplication from below, but I'm now catering to the report
  # code, which may want to get a Linear client without an invoking event to
  # reply to. -- rjbs, 2022-08-13
  my $token = $self->get_user_preference($user, 'api-token');

  return undef unless $token;

  return Linear::Client->new({
    auth_token      => $token,
    _cache_guts     => $self->_linear_shared_cache,
    debug_flogger   => $Logger,

    helper => Synergy::Reactor::Linear::LinearHelper->new_for_reactor($self),
  });
}

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

  my $linear = $self->_linear_client_for_user($user);

  return $code->($linear);
}

sub _slack_item_link ($self, $issue) {
  sprintf "<%s|%s>\N{THIN SPACE}",
    $issue->{url},
    $issue->{identifier};
}

sub _icon_for_issue ($self, $issue) {
  return "\N{SPEAKING HEAD IN SILHOUETTE}" if $issue->{state}{name} eq 'To Discuss';
  return '✓' if $issue->{state}{type} =~ /\A(canceled|completed)\z/n;
  return "\N{FIRE}" if $issue->{priority} == 1;
  return "•";
}

listener issue_mention => sub ($self, $event) {
  my $text = $event->text;

  my $team_name_re = join q{|}, map {; quotemeta } $self->known_team_keys;
  my @matches = $text =~ /\b((?:$team_name_re)-[0-9]+)\b/ig;

  return unless @matches;

  # Do not warn about missing tokens in public about in-passing mentions
  my $user = $event->from_user;
  if ( $event->is_public
    && $user
    && ! $self->get_user_preference($user, 'api-token')
  ) {
    my $rname = $self->name;
    return $event->ephemeral_reply(
      "I saw a Linear issue to expand, but you don't have a Linear API token set."
      . " You should make one, then set your $rname.api-token preference."
    );
  }

  # If there's anything in the message other than identifiers and whitespace,
  # this message had some content other than the identifier.  We remove all the
  # identifiers, then look for anything other than whitespace.  If we were
  # targeted and there was no other payload, it's like this listener was
  # invoked as a command. -- rjbs, 2022-01-26
  $text =~ s/\Q$_\E//g for @matches;

  my $matched_like_command = $event->was_targeted && $text !~ /\S/;

  $event->mark_handled if $matched_like_command;

  # Let's uppercase everything here so it's consistent for the rest of the
  # subroutine.  We'll also drop out dupes while we're here.  -- rjbs,
  # 2022-01-26
  @matches = do {
    my %seen;
    map {; $seen{uc $_}++ ? () : uc $_ } @matches;
  };

  my $declined_to_reply = 0;

  for my $match (@matches) {
    if ($self->has_expanded_issue_recently($event, $match)) {
      $declined_to_reply++;
      next;
    } else {
      $self->note_issue_expansion($event, $match);
    }
  }

  return $event->ephemeral_reply("I've expanded that recently here; just scroll up a bit.")
    if $declined_to_reply;

  $self->_with_linear_client($event, sub ($linear) {
    # We're being a bit gross here.  I'm going to wait_all a collection of
    # futures, then not worry about them being passed into the ->then, because
    # what I really want to do is operate on a key-by-key basis, and hey,
    # they're shared references.  -- rjbs, 2022-01-26
    my %future_for = map {; $_ => $linear->fetch_issue($_) } @matches;

    Future->wait_all(values %future_for)->then(sub {
      my @missing = grep {; ! defined $future_for{$_}->get } @matches;
      my @found   = grep {;   defined $future_for{$_}->get } @matches;

      if (@missing && $matched_like_command) {
        $event->error_reply("I couldn't find some issues you mentioned: @missing");
      }

      for my $found (@found) {
        my $issue = $future_for{$found}->get;

        my $icon = $self->_icon_for_issue($issue);

        my $text = "$found $icon $issue->{title} • $issue->{url}";
        my $slack_link = $self->_slack_item_link($issue);
        $event->reply($text, { slack => "$slack_link $icon $issue->{title}" });
      }

      Future->done;
    });
  });
};

command teams => {
  help => "*teams*: list all the teams in Linear",
} => sub ($self, $event, $rest) {
  if (length $rest) {
    return $event->error_reply(q{"teams" doesn't take any argument.});
  }

  $self->_with_linear_client($event, sub ($linear) {
    $linear->teams->then(sub ($teams) {
      $Logger->log([ "teams response: %s", $teams ]);
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
};

sub _handle_search ($self, $event, $arg) {
  $event->mark_handled;

  my $search = $arg->{search};
  my $zero   = $arg->{zero};
  my $header = $arg->{header};
  my $linear = $arg->{linear};
  my $want_plain = $arg->{plain};

  my $code = sub ($linear) {
    $linear->search_issues($search)->then(sub ($page) {
      unless ($page->payload->{nodes}->@*) {
        return $event->reply($zero);
      }

      my $text  = q{};
      my $slack = q{};

      for my $node ($page->payload->{nodes}->@*) {
        my $icon = $want_plain ? '' : $self->_icon_for_issue($node);
        $text  .= "$node->{identifier} $icon $node->{title}\n";
        $slack .= sprintf "<%s|%s> $icon %s\n",
          $node->{url},
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
  };

  if ($linear) {
    return $code->($linear);
  }

  return $self->_with_linear_client($event, $code);
}

command urgent => {
  help => reformat_help(<<~'EOH'),
    *urgent*: list urgent issues assigned to you
    EOH
} => sub ($self, $event, $rest) {
  if (length $rest) {
    return $event->error_reply(q{"urgent" doesn't take any arguments.});
  }

  $self->_with_linear_client($event, sub ($linear) {
    $self->_handle_search(
      $event,
      {
        search => {
          assignee => { isMe => { eq => \1 } },
          priority => 1,
          closed   => 0,
        },
        zero   => "There's nothing urgent, so take it easy!",
        header => "Urgent issues for you",
        linear => $linear,
      }
    );
  });
};

command sb => {
  help => reformat_help(<<~'EOH'),
    *sb `WHO`*: list unassigned support-blocking issues in Linear

    This will list open issues in Linear tagged "support blocker".  If you name
    someone, it will list issues assigned to that person.  Otherwise, it lists
    unassigned support blockers.
    EOH
} => sub ($self, $event, $who) {
  if (length $who) {
    my $user = $self->resolve_name($who, $event->from_user);
    unless ($user) {
      return $event->error_reply(qq{I can't figure out who "$who" is.});
    }

    $who = $user->username;
  }

  $self->_with_linear_client($event, sub ($linear) {
    my $when  = length $who
              ? $linear->lookup_user($who)->then(sub ($user) {
                  return Future->fail("no such user") unless $user;
                  return Future->done(assignee => $user->{id});
                })
              : Future->done(assignee => undef);

    $when->then(sub {
      my (%extra_search) = @_;

      $self->_handle_search(
        $event,
        {
          search => {
            label     => 'support blocker',
            closed    => 0,
            %extra_search
          },
          zero   => "No support blockers!  Great!",
          header => "Current support blockers",
          linear => $linear,
        },
      );
    });
  });
};

sub sb_report ($self, $who, $arg = {}) {
  my $linear = $self->_linear_client_for_user($who);

  return Future->done([]) unless $linear;

  my $search = $linear->search_issues({
    label     => 'support blocker',
    closed    => 0,
    assignee  => undef,
  });

  $search->then(sub ($page) {
    # XXX This is not perfect.  If we have more than one page of blockers
    # (ugh!) it will only get the first page.  More later, maybe?
    # -- rjbs, 2022-08-13
    my $count = $page->payload->{nodes}->@*;

    if ($count == 0) {
      my $msg = "\N{HELMET WITH WHITE CROSS} There are no support blockers.";
      return Future->done([
        $msg, { slack => $msg },
      ]);
    }

    my $msg = sprintf "\N{HELMET WITH WHITE CROSS} There are %s support %s.",
      $count,
      PL_N('blocker', $count);

    return Future->done([ $msg, { slack => $msg } ]);
  });
}

command triage => {
  help => reformat_help(<<~'EOH'),
    *triage `[TEAM]`*: list unassigned issues in the Triage state

    This lists (the first page of) all unassigned issues in the Triage state in
    Linear.  You can supply an argument, the name of a team, to see only issues
    for that team.
    EOH
} => sub ($self, $event, $team_name) {
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
          search => {
            state    => 'Triage',
            assignee => undef,
            %extra_search,
          },
          zero   => "No unassigned issues in triage!  Great!",
          header => "Current unassigned triage work",
          linear => $linear,
        }
      );
    })->else(sub {
      $event->error_reply("I couldn't find the team you asked about!");
    });
  });
};

command agenda => {
  help => reformat_help(<<~'EOH'),
    *agenda `[TARGET]`*: list issues in the To Discuss state

    This command lists issues in the state To Discuss.  If a target is given
    (either a user name, a team name, or user@team), only issues with that
    assignment are listed. With `/plain`, suppress issue icons (useful for
    pasting into Notion). With `/current`, limit items to those scheduled for
    the current cycle.
    EOH
} => sub ($self, $event, $spec) {
  my $want_plain = $spec =~ s!\s+/plain\b!!;

  my %current;
  if ($spec =~ s!\s+/current\b!!) {
    %current = (
      cycle => {
        isActive => { eq => JSON::MaybeXS::true() }
      },
    );
  }

  my $include_assigned =
    $self->get_user_preference($event->from_user, 'agenda-shows-assigned');

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
                      return Future->done(
                        team => $team_id,
                        ($include_assigned ? () : (assignee => undef)),
                      );
                    }
                  }
                })
              : Future->done(assignee => { isMe => { eq => \1 } }); 

    $when->then(sub {
      my (%extra_search) = @_;
      $self->_handle_search(
        $event,
        {
          search => {
            state    => 'To Discuss',
            %current,
            %extra_search,
          },
          zero   => "You have nothing on the agenda",
          header => "Current agenda",
          linear => $linear,
          plain  => $want_plain,
        }
      );
    })->else(sub {
      $event->error_reply("I couldn't find the team you asked about!");
    });
  });
};

sub _handle_creation_event ($self, $event, $arg = {}) {
  $event->mark_handled;

  my $plan_munger = $arg->{plan_munger};
  my $linear      = $arg->{linear};
  my $ersatz_text = $arg->{ersatz_text};

  my $code = sub ($linear) {
    my $slack_link = $event->event_uri;
    my $text = $event->text . "\n\ncreated at: $slack_link";

    # Slack now "helpfully" corrects '>>' in DM to '> >'.
    $text =~ s/\A> >/>>/;

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
            sprintf("I made that issue, %s: %s", $id, $url),
            {
              slack => sprintf("I made that issue, <%s|%s>.", $url, $id),
            },
          );
        } else {
          return $event->error_reply(
            "Sorry, something went wrong and I can't say what!"
          );
        }
      })
      ->else(sub ($error) { $event->error_reply("Couldn't make issue: $error") });
  };

  if ($linear) {
    return $code->($linear);
  }

  $self->_with_linear_client($event, $code);
}

responder new_issue => {
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($text, @) {
    return unless $text =~ s/\A ( \+\+ | >\s?> ) \s+//x;
    my $which = $1 eq '++' ? '++' : '>>';

    return [ $which, $text ];
  },
  # The stupid zero width space below is to prevent Slack from turning >> into
  # a block quoted >. -- rjbs, 2022-02-08
  help_titles => [ qw( >> ++ ) ],
  help      => reformat_help(<<~"EOH"),
    *\N{ZERO WIDTH SPACE}>> `TARGET` `NAME`*: create a new issue in Linear
    *++ `NAME`*: create a new issue in Linear, with you as the target

    In the simplest form, this creates a new issue with the given name, assigned
    to the given target.  (More on "targets" below.)  Any text after a line
    break or after triple dashes (`---`) becomes part of the long form
    description of the issue, using Markdown.

    The `TARGET` can be either:
    • a username
    • a team name
    • username\@team

    If only a username is given, the issue is assigned to that user in their
    default team.  If only a team name is given, the issue is created
    unassigned in that team.  If both are given, the issue is created in the
    given team and assigned to the given user.

    If `NAME` ends with `(!)` or 🔥 it will be marked urgent.  If it ends with
    `(?)` or ☎️ it will be created in the To Discuss state.  These two markers
    can be present in any order.
    EOH
} => sub ($self, $event, $which, $text) {
  if ($event->text =~ /\A>> triage /i) {
    $event->mark_handled;
    return $event->error_reply(q{You can't assign directly to triage anymore.  Instead, use the Zendesk integration!  You can also look at help for "ptn blocked".});
  }

  $self->_handle_creation_event($event);
};

responder ptn_blocked => {
  targeted  => 1,
  exclusive => 1,
  matcher   => sub ($text, @) {
    my ($ptn, $rest) = $text =~ m{\Aptn\s*([0-9]+) blocked:\s*(.+)}is;
    return unless $ptn;

    return [ $ptn, $rest ];
  },
  help      => reformat_help(<<~'EOH'),
    *ptn `NUMBER` blocked: `DESC`*: create a new support-blocking Linear issue

    This command will create a new issue in Linear, much like `>>`.  It assigns
    the issue to plumbing and tags it *support blocker*.  The `DESC` is what
    you'd put after `>> plumbing` if you were using `>>`.

    *In general, don't use this!*  Instead, use the Zendesk integration.
    EOH
} => sub ($self, $event, $ptn, $rest) {
  my $new_text = ">> plumb $rest";

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
};

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
  description => "Default team for your Linear issues",
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

__PACKAGE__->add_preference(
  name      => 'agenda-shows-assigned',
  help      => "Whether the agenda command shows assigned items or not (yes/no)",
  default   => 1,
  validator => sub ($self, $value, @) { return bool_from_text($value) },
);

1;
