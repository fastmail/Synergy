use v5.32.0;
use warnings;
package Synergy::Reactor::Linear;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::DeduplicatesExpandos' => {
       expandos => [ 'issue' ],
     };

use experimental qw(signatures lexical_subs try);
use namespace::clean;
use Feature::Compat::Defer;

use Future::AsyncAwait;
use Linear::Client;
use Lingua::EN::Inflect qw(PL_N);

use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(bool_from_text reformat_help);
use String::Switches;

use POSIX qw(ceil);

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

  sub expand_team_as_macro ($self, $team_name) {
    my $macros = $self->{reactor}->team_macros;
    return unless $macros;
    return unless my $macro = $macros->{lc $team_name};
    return $macro;
  }

  sub team_id_for_username ($self, $username) {
    $Logger->log("doing team lookup for $username");
    my $team_id = $self->{reactor}
                       ->get_user_preference($username, 'default-team');
    return $team_id;
  }

  # Okay, sorry, this subroutine is Extremely Fastmail™. -- rjbs, 2022-10-06
  sub project_ids_for_tag ($self, $tag) {
    my $notion = $self->{reactor}->hub->reactor_named('notion');

    unless ($notion) {
      return Future->done;
    }

    return $notion->_project_pages->then(sub (@pages) {
      @pages = grep {;
        ($_->{properties}{Hashtag}{rich_text}[0]{plain_text} // '') eq $tag
      } @pages;

      my @slug_ids =
        map  {; m{-([a-z0-9]+)(?:/[A-Z]+)?\z} ? $1 : () }
        grep {; length }
        map  {; $_->{properties}{'Linear Project'}{url} }
        @pages;

      Future->done(@slug_ids);
    });
  }
}

has attachment_icon_url => (
  is => 'ro',
);

has team_aliases => (
  reader  => '_team_aliases',
  default => sub {  {}  },
  traits  => [ 'Hash' ],
  handles => {
    known_team_keys  => 'keys',
  }
);

has team_macros => (
  is => 'ro',
  traits  => [ 'Hash' ],
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

  return '✗' if $issue->{state}{type} eq 'canceled';
  return '✓' if $issue->{state}{type} eq 'completed';

  return "\N{FIRE}" if $issue->{priority} == 1;

  return "•";
}

listener issue_mention => async sub ($self, $event) {
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
    return await $event->ephemeral_reply(
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

  return await $event->ephemeral_reply("I've expanded that recently here; just scroll up a bit.")
    if $declined_to_reply;

  await $self->_with_linear_client($event, async sub ($linear) {
    # We're being a bit gross here.  I'm going to wait_all a collection of
    # futures, then not worry about them being passed into the ->then, because
    # what I really want to do is operate on a key-by-key basis, and hey,
    # they're shared references.  -- rjbs, 2022-01-26
    my %future_for = map {; $_ => $linear->fetch_issue($_) } @matches;

    await Future->wait_all(values %future_for);

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
  });
};

command teams => {
  help => "*teams*: list all the teams in Linear",
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->error_reply(q{"teams" doesn't take any argument.});
  }

  await $self->_with_linear_client($event, async sub ($linear) {
    my $teams = await $linear->teams;

    my $text  = qq{Teams in Linear\n};
    my $slack = qq{*Teams in Linear*\n};
    for my $team_key (sort keys %$teams) {
      my $this = sprintf "%s — %s\n", uc $team_key, $teams->{$team_key}{name};
      $text  .= $this;
      $slack .= $this;
    }

    return await $event->reply($text, { slack => $slack });
  });
};

async sub _handle_search ($self, $event, $arg) {
  $event->mark_handled;

  my $search = $arg->{search};
  my $zero   = $arg->{zero};
  my $header = $arg->{header};
  my $linear = $arg->{linear};
  my $want_plain = $arg->{plain};

  my $code = async sub ($linear) {
    my $page = await $linear->search_issues($search);

    unless ($page->payload->{nodes}->@*) {
      return await $event->reply($zero);
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

    return await $event->reply(
      "$header:\n$text",
      { slack => "*$header:*\n$slack" },
    );
  };

  if ($linear) {
    return await $code->($linear);
  }

  return await $self->_with_linear_client($event, $code);
}

command search => {
  help => reformat_help(<<~'EOH'),
    *search* TEXT [page:N] [count:N] [all:1]

    Searches linear the same way advanced search does (but only for
    tickets/comments).

    Arguments:

    • TEXT     - The string(s) to search
    • page:N   - Which page of results to retrieve, if there's more than 1
    • count:N  - Return N results. Default is 10. Any more will be a private response
    • all:1    - Include tasks in the canceled/completed states also
    EOH
} => async sub ($self, $event, $rest) {
  await $self->_with_linear_client($event, async sub ($linear) {
    my $fallback = sub ($text_ref) {
      ((my $token), $$text_ref) = split /\s+/, $$text_ref, 2;

      return [ search => $token ];
    };

    my $hunks = String::Switches::parse_colonstrings($rest, { fallback => $fallback });

    my $wpage = 1;
    my $count = 10;
    my $include_all = 0; # by default, ignore closed
    my $terms = "";
    my $debug;

    for my $cond (@$hunks) {
      my ($name, $val) = @$cond;

      if ($name eq 'page') {
        $wpage = $val;
      } elsif ($name eq 'count') {
        $count = $val;
      } elsif ($name eq 'all' && $val) {
        $include_all = 1;
      } elsif ($name eq 'debug') {
        $debug = 1;
      } elsif ($name eq 'search') {
        $terms .= "$val ";
      } else {
        return $event->error_reply("Unknown option $name:$val...");
      }
    }

    $terms =~ s/\s+$//;

    unless (length $terms) {
      return $event->error_reply("You didn't ask me to search for anything...");
    }

    $event->mark_handled;

    my $linear = $self->_linear_client_for_user($event->from_user);
    unless ($linear) {
      return await $event->reply("You don't have a linear token...");
    }

    my $orig_lc;

    if ($debug) {
      $orig_lc = $linear->log_complexity;

      $linear->log_complexity(1);
    }

    defer { $linear->log_complexity($orig_lc); };

    my $filter = {};

    if (! $include_all) {
      $filter->{state} = {
        type => {
          nin => [ qw( canceled completed ) ]
        }
      }
    };

    my $query_result = await $linear->do_paginated_query({
      query_name => 'searchIssues',
      query_args => {
        filter => $filter,
        includeArchived => \1,
        term => $terms,
        first => 0+$count,
      },
      nodes_select => [
        qw(id metadata identifier url priority title),
        assignee => [ qw(name id) ],
        state => [ qw(name type) ],
      ],
      extra_select => [ qw(totalCount) ],
    });

    unless ($query_result->payload) {
      $Logger->log([
        "Hmm, didn't get expected response. Instead got %s",
        $query_result->raw_payload
      ]);

      return $event->error_reply("Sorry, that query returned something unexpected...");
    }

    my $cpage = 1;

    while ($wpage > $cpage) {
      unless ($query_result->has_next_page) {
        return await $event->reply("You requested page $wpage, out of range (max: $cpage)");
      }

      $cpage++;

      $query_result = await $query_result->next_page;

      unless ($query_result->payload) {
        $Logger->log([
          "Hmm, didn't get expected response. Instead got %s",
          $query_result->raw_payload
        ]);

        return $event->error_reply("Sorry, that query returned something unexpected after $cpage pages...");
      }
    }

    my $text = my $slack = "*Your results for «$terms»*\n";

    for my $node ($query_result->payload->{nodes}->@*) {
      my $id = $node->{identifier};
      my $url = $node->{url};
      my $assignee = $node->{assignee}{name} // '<nobody>';
      my $state = $node->{state}{name};
      my $title = $node->{title};

      my $icon = $self->_icon_for_issue($node);

      my $snippet;
      my $highlights;
      my $is_title;

      PATH: for my $path ([qw(title)], [qw(comment body)], [qw(description)]) {
        my $t = $node->{metadata}->{context};

        my $last_path;

        for my $k (@$path) {
          $t = $t->{$k};

          next PATH unless $t;

          $last_path = $k;
        }

        next PATH unless $t->{highlights};

        $is_title = 1 if $last_path eq 'title';

        $snippet = $t->{snippet};
        $highlights = $t->{highlights};

        last;
      }

      unless ($highlights) {
        $Logger->log(["No highlights in response to search?: %s", $node]);

        $highlights = [];
      }

      unless ($snippet) {
        $Logger->log(["No snippet in response to search?: %s", $node]);

        # Force title only output
        $is_title = 1;
      }

      $text  .= "$id $icon $title (_assignee_: $assignee)";

      if (@$highlights && $snippet) {
        $text .= "found [ @$highlights ] in $snippet\n";
      }

      if ($is_title) {
        $title =~ s/$_/*$_*/g for @$highlights;
        $title =~ s/\*@|@\*/*/g;
        $title =~ s/`//g;

        $slack .= sprintf "<%s|%s> $icon %s (_assignee_: %s)\n",
          $url,
          $id,
          $title,
          $assignee,
      } else {
        $snippet =~ s/$_/*$_*/g for @$highlights;
        $snippet =~ s/\n/ /g;
        $snippet =~ s/\*@|@\*/*/g;
        $snippet =~ s/`//g;

        $slack .= sprintf "<%s|%s> $icon %s (_assignee_: %s)\n>%s\n",
          $url,
          $id,
          $title,
          $assignee,
          $snippet;
      }
    }

    my $total = $query_result->payload->{totalCount};
    my $pages = ceil($total / $count);

    # Apparently 500 means "We gave up counting". UI adds the "+" too
    $total .= "+" if $total == 500;

    $text  .= "*[Page $cpage/$pages ($total issues)]*\n";
    $slack .= "*[Page $cpage of $pages ($total issues)]*\n";

    chomp $text;
    chomp $slack;

    my $method = 'reply';

    if ($count > 10 && $event->is_public) {
      await $event->reply("I'll respond privately since you want more than 10 results\n");

      $method = 'private_reply';
    }

    return await $event->$method(
      "$text",
      { slack => "$slack" },
    );
  });
};

command urgent => {
  help => reformat_help(<<~'EOH'),
    *urgent*: list urgent issues assigned to you
    EOH
} => async sub ($self, $event, $rest) {
  if (length $rest) {
    return await $event->error_reply(q{"urgent" doesn't take any arguments.});
  }

  await $self->_with_linear_client($event, async sub ($linear) {
    await $self->_handle_search(
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
} => async sub ($self, $event, $who) {
  if (length $who) {
    my $user = $self->resolve_name($who, $event->from_user);
    unless ($user) {
      return await $event->error_reply(qq{I can't figure out who "$who" is.});
    }

    $who = $user->username;
  }

  await $self->_with_linear_client($event, async sub ($linear) {
    my %extra_search;

    if (length $who) {
      my $user = await $linear->lookup_user($who);
      die "no such user" unless $user;

      %extra_search = (assignee => $user->{id});
    } else {
      %extra_search = (assignee => undef);
    }

    return await $self->_handle_search(
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
};

async sub sb_report ($self, $who, $arg = {}) {
  my $linear = $self->_linear_client_for_user($who);

  return [] unless $linear;

  my $page = await $linear->search_issues({
    label     => 'support blocker',
    closed    => 0,
    assignee  => undef,
  });

  # XXX This is not perfect.  If we have more than one page of blockers
  # (ugh!) it will only get the first page.  More later, maybe?
  # -- rjbs, 2022-08-13
  my $count = $page->payload->{nodes}->@*;

  if ($count == 0) {
    my $msg = "\N{HELMET WITH WHITE CROSS} There are no support blockers.";
    return [ $msg, { slack => $msg } ];
  }

  my $msg = sprintf "\N{HELMET WITH WHITE CROSS} There are %s support %s.",
    $count,
    PL_N('blocker', $count);

  return [ $msg, { slack => $msg } ];
}

command triage => {
  help => reformat_help(<<~'EOH'),
    *triage `[TEAM]`*: list unassigned issues in the Triage state

    This lists (the first page of) all unassigned issues in the Triage state in
    Linear.  You can supply an argument, the name of a team, to see only issues
    for that team.
    EOH
} => async sub ($self, $event, $team_name) {
  await $self->_with_linear_client($event, async sub ($linear) {
    my %extra_search;

    if (length $team_name) {
      my $team = await $linear->lookup_team($team_name);

      unless ($team) {
        return await $event->error_reply("I couldn't find the team you asked about!");
      }

      %extra_search = (team => $team->{id});
    }

    return await $self->_handle_search(
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
  });
};

command agenda => {
  help => reformat_help(<<~'EOH'),
    *agenda `[TARGET]`*: list issues in the To Discuss state

    This command lists issues in the state To Discuss.  If a target is given
    (either a user name, a team name, user@team, or ##project), only matching
    issues are listed. With `/plain`, suppress issue icons (useful for pasting
    into Notion). With `/current`, limit items to those scheduled for
    the current cycle.
    EOH
} => async sub ($self, $event, $spec) {
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

  await $self->_with_linear_client($event, async sub ($linear) {
    my %extra_search;

    if (length $spec) {
      if ($spec =~ s/^##//) {
        my ($project, $error) = await $self->project_for_tag($linear, $spec);

        if ($error) {
          return await $event->reply($error);
        }

        %extra_search = (project => $project->{id});
      } else {
        my ($assignee_id, $team_id);

        try {
          ($assignee_id, $team_id) = await $linear->who_or_what($spec);
        } catch ($error) {
          # Is it really worth logging?
          return await $event->error_reply(q{I couldn't figure out which team's agenda you wanted.});
        }

        if ($spec =~ /@/) {
          %extra_search = (assignee => $assignee_id, team => $team_id);
        } else {
          # Okay they said 'agenda foo'. Foo could be a team or a user.  If it's
          # a user, they want all agenda items for that user, so we need to
          # ignore the team.
          %extra_search = $assignee_id
            ? (assignee => $assignee_id)
            : (team => $team_id, ($include_assigned ? () : (assignee => undef)));
        }
      }
    } else {
      %extra_search = (assignee => { isMe => { eq => \1 } });
    }

    return await $self->_handle_search(
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
  });
};

async sub project_for_tag ($self, $linear, $tag) {
  my @slug_ids = await $linear->helper->project_ids_for_tag($tag);

  unless (@slug_ids) {
    return (undef, q{I couldn't find that project in Notion.});
  }

  if (@slug_ids > 1) {
    return (undef, qq{Sorry, ##$tag is on more than one project!});
  }

  my $projects = await $linear->projects;

  my ($project) = grep {; $_->{slugId} eq $slug_ids[0] } values %$projects;

  unless ($project) {
    return (undef, qq{Sorry, I couldn't find that project in Linear!});
  }

  return ($project, undef);
}

command update => {
  help => reformat_help(<<~'EOH'),
    *update `##PROJECT`: `TEXT` [/`ontrack|atrisk|offtrack`]*: post a project update
  EOH
} => async sub ($self, $event, $rest) {
  state %canonical = (
    ontrack   => 'onTrack',
    atrisk    => 'atRisk',
    offtrack  => 'offTrack',
  );

  await $self->_with_linear_client($event, async sub ($linear) {
    my ($tag, $rest) = split /\s+/, $rest, 2;

    unless ($tag =~ /^##[-a-zA-Z]+\z/) {
      return await $event->error_reply(q{The first thing after "update" has to be a `##project` tag.});
    }

    my $health;
    if ($rest =~ s{\s+/(ontrack|atrisk|offtrack)\s*\z}{}i) {
      $health = $canonical{ lc $1 };
    }

    $tag =~ s/\A##//;

    my ($project, $error) = await $self->project_for_tag($linear, $tag);

    if ($error) {
      return await $event->error_reply($error);
    }

    my $query_result = await $linear->post_project_update($project->{id}, {
      body   => $rest,

      ($health ? (health => $health) : ()),
    });

    my $ok = $query_result->{data}{projectUpdateCreate}{success};

    if ($ok) {
      return await $event->reply("Update posted!");
    }

    $Logger->log([ "problem posting project update: %s", $query_result ]);
    return await $event->error_reply("Something went wrong, but I have no idea what.");
  });
};

async sub _handle_creation_event ($self, $event, $arg = {}) {
  $event->mark_handled;

  my $plan_munger = $arg->{plan_munger};
  my $linear      = $arg->{linear};
  my $ersatz_text = $arg->{ersatz_text};

  my $code = async sub ($linear) {
    my $text = $event->text;

    # Slack now "helpfully" corrects '>>' in DM to '> >'.
    $text =~ s/\A> >/>>/;

    # XXX: I do not like our current error-returning scheme. -- rjbs, 2021-12-10
    my $plan;
    try {
      $plan = await $linear->plan_from_input($ersatz_text // $text);
    } catch ($err) {
      return await $event->error_reply("Sorry, that didn't work: $err");
    }

    $plan_munger->($plan) if $plan_munger;

    my $query_result = await $linear->create_issue($plan);

    # XXX The query result is stupid and very low-level.  This will change.
    my $id  = $query_result->{data}{issueCreate}{issue}{identifier};
    my $url = $query_result->{data}{issueCreate}{issue}{url};

    if ($id && $event->event_uri) {
      my $type = $event->is_public ? "Synergy" : "private Synergy";
      my $icon = $self->attachment_icon_url;

      $linear->add_attachment_to_issue($id, {
        url   => $event->event_uri,
        title => "Created via $type message",
        ($icon ? (iconUrl => $icon) : ()),
      });
    }

    if ($id) {
      return await $event->reply(
        sprintf("I made that issue, %s: %s", $id, $url),
        {
          slack => sprintf("I made that issue, <%s|%s>.", $url, $id),
        },
      );
    }

    $Logger->log([ "problem creating issue: %s", $query_result ]);
    return await $event->error_reply("Sorry, something went wrong and I can't say what!");
  };

  if ($linear) {
    return await $code->($linear);
  }

  return await $self->_with_linear_client($event, $code);
}

command comment => {
  help => "*comment on `ISSUE`: `comment`*: add a comment to a linear issue",
} => async sub ($self, $event, $rest) {
  unless ($rest) {
    return await $event->error_reply("I don't know what you want me to comment on.")
  }

  my ($issue_ident, $comment) = $rest =~ /
    ^
    (?:on\s+)?
    ([a-z]+-[0-9]*)
    :?
    \s+
    (.*)
    \z
  /ix;

  unless ($issue_ident && $comment) {
    return await $event->error_reply("I don't know what you want me to comment on.");
  }

  await $self->_with_linear_client($event, async sub ($linear) {
    my $issue   = await $linear->fetch_issue($issue_ident);
    my $comment_res = await $linear->create_comment({
      issueId => $issue->{id},
      body    => $comment
    });

    my $comment_id = $comment_res->{data}{commentCreate}{comment}{id};
    my $url = $comment_res->{data}{commentCreate}{comment}{url};

    if ($comment_id) {
      my $text = sprintf("I added that comment to %s: %s.", $url, $issue_ident);
      my $slack = sprintf("I added that comment to <%s|%s>.", $url, $issue_ident);
      return await $event->reply($text, { slack => $slack });
    }

    $Logger->log([ "error trying to create a comment on %s: %s", $issue_ident, $comment_res ]);
    return await $event->error_reply("Sorry, something went wrong and I can't say what!");
  });
};

responder new_issue => {
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($text, @) {
    return unless $text =~ /\A ( \+\+ (\@\w+)? | >\s?> ) \s+/nx;
    return [];
  },
  # The stupid zero width space below is to prevent Slack from turning >> into
  # a block quoted >. -- rjbs, 2022-02-08
  help_titles => [ qw( >> ++ ) ],
  help      => reformat_help(<<~"EOH"),
    *\N{ZERO WIDTH SPACE}>> `TARGET` `NAME`*: create a new issue in Linear
    *++ `NAME`*: create a new issue in Linear, with you as the target
    *++\@`TEAM` `NAME`*: create a new issue, targeting you in a specific team

    This creates a new issue with the given name, assigned to the given target.

    The `TARGET` can be either:
    • a username
    • a team name
    • username\@team

    If only a username is given, the issue is assigned to that user in their
    default team.  If only a team name is given, the issue is created
    unassigned in that team.  If both are given, the issue is created in the
    given team and assigned to the given user.

    The `NAME` value can be multiple lines.  Its first line is the issue's
    title, and the rest is switches and the issue description.  It works like
    this:  after the first line, we take aside every line that starts with a
    `/` and those lines are treated as switches (see below).  Once we find a
    line that isn't switches, the rest of the input is the Linear issue's
    description.  Instead of splitting with line breaks, you can use `---`.

    Switches are in the form `/name value`, and the value is sometimes
    optional.  You can provide switches to change properties of newly-created
    issues.  Here are valid switches:

    • /est E      - add the estimate _E_ to the issue (/estimate works too)
    • /label L    - add the label _L_ to the issue
    • /state S    - set the issue's starting state to _S_
    • /project P  - put the issue into project _P_ (by hashtag)
    • /priority P - set the issue's priority (low, medium, high, urgent)

    There are more shorthand switches:

    • /urgent - short for: /priority urgent
    • /start - short for: /state "In Progress"
    • /discuss - short for: /state "To Discuss"
    • /done - short for: /state Done; will put the issue into current cycle
    • /bug, /chore, /debt, /dev, /gear, /standards - short for /label-ing the issue

    Some switches have _even shorter_ shorthand.  If the issue title would end
    with `(!)` or 🔥, it's treated like `/urgent`.  If it ends with `(?)` or ☎️ ,
    it's treated like `/discuss`.  Finally, if it ends with `##hashtag`, this
    is treated as short for `/project hashtag`.
    EOH
} => sub ($self, $event) {
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
} => async sub ($self, $event, $ptn, $rest) {
  my $new_text = ">> plumb $rest";

  return await $self->_with_linear_client($event, async sub ($linear) {
    my $label_id = await $linear->lookup_team_label("plu", "support blocker");

    return await $self->_handle_creation_event(
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
