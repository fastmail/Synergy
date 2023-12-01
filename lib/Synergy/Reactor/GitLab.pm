use v5.32.0;
use warnings;
use utf8;
package Synergy::Reactor::GitLab;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::DeduplicatesExpandos' => {
       expandos => [qw( mr commit )],
     };

use experimental qw(lexical_subs signatures);
use namespace::clean;
use DateTime::Format::ISO8601;
use Digest::MD5 qw(md5_hex);
use Future 0.36;  # for ->retain
use Future::AsyncAwait;
use IO::Async::Timer::Periodic;
use JSON::MaybeXS;
use Lingua::EN::Inflect qw(PL_N PL_V);
use List::Util qw(all uniq);
use MIME::Base64;
use POSIX qw(ceil);
use String::Switches;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(reformat_help);
use Time::Duration qw(ago);
use URI::Escape;
use YAML::XS;

my $JSON = JSON::MaybeXS->new->utf8->canonical;

has api_token => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_uri => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has url_base => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  default => sub { $_[0]->api_uri =~ s|/api$||r; },
);

has project_shortcuts => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  writer => '_set_shortcuts',
  handles => {
    _is_known_project => 'exists',
    _project_named    => 'get',
    all_shortcuts    => 'keys',
    add_shortcuts    => 'set',
  }
);

sub is_known_project ($self, $key) { $self->_is_known_project(lc $key) }
sub project_named    ($self, $key) { $self->_project_named(lc $key) }

has custom_project_shortcuts => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
);

has relevant_owners => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub { [] },
);

has group_emoji => (
  isa => 'HashRef',
  default => sub {  {}  },
  traits  => [ 'Hash' ],
  handles => { emoji_for => 'get' },
);

has default_group_emoji => (
  is => 'ro',
  default => '➖',
);

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    my $repo_state = $state->{repos} // {};
    $self->_set_shortcuts($repo_state);
  }
};

async sub start ($self) {
  $self->add_shortcuts($self->custom_project_shortcuts->%*);

  $self->hub->loop->delay_future(after => 60)->then(sub {
    $Logger->log("loading shortcuts from GitLab");
    $self->_load_auto_shortcuts;
  })->retain;

  return;
}

sub state ($self) {
  return {
    repos => $self->project_shortcuts,
  };
}

my %MR_SHORTCUT = (
  todo    => 'by:!me for:me backlogged:no',
  ready   => 'by:me for:me approved:yes',
  waiting => 'by:me for:!me for:* backlogged:no',
);

command "mrsearch" => {
  aliases => [ "mrs" ],
  help    => reformat_help(<<~'EOH'),
    The *mrsearch* command searches merge requests in GitLab.  You can pass in
    a list of colon-separated pairs like *for:me* to limit the results, or just
    words to search for.  Here are the arguments you can pass:

    • *for:`USER`*: MRs assigned to the named user; `*` for "assigned to
    anybody" or `~` for "assigned to nobody"
    • *by:`USER`*: MRs authored by the named user
    • *approved:`{yes,no,both}`*: only MRs that are (or are not) approved to merge
    • *label:`LABEL`*: MRs with the given label; `*` for "has a label at all"
    or `~` for "has no labels"
    • *backlogged:`{yes,no,both}`*: whether or not to include MRs with the
    "backlogged" label
    • *wip:`{yes,no,both}`*: whether or not to include works in progress

    Alternatively, you can just pass a single argument as a shortcut:
    • *todo*: MRs that are waiting for your review
    • *waiting*: MRs you sent out for review
    • *ready*: MRs that you wrote, are assigned to you, and are approved
    EOH
} => async sub ($self, $event, $rest) {
  unless (length $rest) {
    return await $event->error_reply("What should I search for?  (Maybe look at `help mrsearch`?)");
  }

  # Fun fact: we document only "mrs todo" but "mrs todo x:y" works, 99% so that
  # you can say "mrs todo page:2" -- rjbs, 2021-11-29
  if ($rest =~ s/\A([a-z]\S+)(\s|$)//i) {
    $rest = ($MR_SHORTCUT{$1} // $1) . " $rest";
    $rest =~ s/\s+$//;
  }

  return await $self->_handle_mr_search_string($rest, $event);
};

command 'r?' => {
  help => reformat_help(<<~'EOH'),
    This is short for `mrsearch for:me backlogged:no` -- in other words, "what
    can I act on right now?".
    EOH
} => async sub ($self, $event, $rest) {
  return await $self->_handle_mr_search_string("for:me backlogged:no", $event);
};

listener merge_request_mention => async sub ($self, $event) {
  my $text = $event->text;

  # Don't have a bot loop.  (There are better ways to deal with this later.)
  return if $text =~ /^\s*\@?bort/i;

  my $base = $self->url_base;
  unless (
    $text =~ /\b[-_a-z]+!\d+(\W|$)/in
    ||
    $text =~ /\Q$base\E.*?merge_requests/
  ) {
    # No mention, move on.
    return;
  }

  my @mrs = $text =~ /\b([-_a-z]+!\d+)(?=\W|$)/gi;

  $text =~ s/\Q$_// for @mrs;

  $event->mark_handled if $event->was_targeted && $text !~ /\S/;

  my @found = $event->text =~ m{\Q$base\E/(.*?/.*?)(?:/-)?/merge_requests/([0-9]+)}g;

  while (my ($key, $num) = splice @found, 0, 2) {
    push @mrs, "$key!$num";
  }

  @mrs = uniq @mrs;
  my @futures;
  my $replied = 0;
  my $declined_to_reply = 0;

  MR: for my $mr (@mrs) {
    my ($proj, $num) = split /!/, $mr, 2;

    # $proj might be a shortcut, or it might be an owner/repo string
    my $project_id = $self->is_known_project($proj)
                   ? $self->project_named($proj)
                   : $proj;

    my $url = sprintf("%s/v4/projects/%s/merge_requests/%d",
      $self->api_uri,
      uri_escape($project_id),
      $num,
    );

    my $mr_get = $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    # approval status is a separate call (sigh)
    my $approval_get = $self->hub->http_get(
      "$url/approvals",
      'PRIVATE-TOKEN' => $self->api_token,
    );

    await Future->wait_all($mr_get, $approval_get);

    my $mr_res = $mr_get->get;
    my $approval_res = $approval_get->get;

    unless ($mr_res->is_success) {
      $Logger->log([ "Error fetching MR: %s", $mr_res->as_string ]);
      next MR;
    }

    unless ($approval_res->is_success) {
      $Logger->log([ "Error fetching approvals: %s", $approval_res->as_string ]);
      next MR;
    }

    my $data = $JSON->decode($mr_res->decoded_content);
    my $approval_data = $JSON->decode($approval_res->decoded_content);

    my $is_approved = $approval_data->{approved};

    if ($self->has_expanded_mr_recently($event, $data->{id})) {
      $event->ephemeral_reply("I've expanded $mr recently here; just scroll up a bit.");
      $declined_to_reply++;
      next MR;
    }

    $self->note_mr_expansion($event, $data->{id});

    my $state = $data->{state};

    my $reply = "$mr [$state, created by $data->{author}->{username}]: ";
    $reply   .= "$data->{title} ($data->{web_url})";

    my $color = $state eq 'opened' ? '#1aaa4b'
              : $state eq 'merged' ? '#1f78d1'
              : $state eq 'closed' ? '#db3b21'
              : undef;

    my @fields;
    if ($state eq 'opened') {
      my $assignee = $data->{assignee}{name} // 'nobody';
      push @fields, {
        title => "Assigned",
        value => $assignee,
        short => \1
      };

      my $created = DateTime::Format::ISO8601->parse_datetime($data->{created_at});

      push @fields, {
        title => "Opened",
        value => ago(time - $created->epoch),
        short => \1,
      };
    } else {
      my $date = $data->{merged_at} // $data->{closed_at};
      if ($date) {
        # Huh! Turns out, sometimes MRs are marked merged or closed, but do
        # not have an associated timestamp. -- michael, 2018-11-21
        my $dt = DateTime::Format::ISO8601->parse_datetime($date);
        push @fields, {
          title => ucfirst $state,
          value => ago(time - $dt->epoch),
          short => \1,
        };
      }
    }

    my $approval_str = join q{, },
      ($data->{work_in_progress} ? 'Work in progress' : ()),
      ($is_approved ? "Approved" : "Not yet approved");

    my $dv = $data->{downvotes};
    my $downvote_str = $dv
                     ? sprintf(' (%s %s)', $dv, PL_N('downvote', $dv))
                     : '';

    push @fields, {
      title => "Review status",
      value => $approval_str . $downvote_str,
      short => \1
    };

    if (my $pipeline = $data->{pipeline}) {
      my $status = ucfirst $pipeline->{status};
      $status =~ s/_/ /g;
      push @fields, {
        title => "Pipeline status",
        value => $status,
        short => \1,
      };
    }

    my $slack = {
      text        => "",
      attachments => [{
        fallback    => "$mr: $data->{title} [$data->{state}] $data->{web_url}",
        author_name => $data->{author}->{name},
        author_icon => $data->{author}->{avatar_url},
        title       => "$mr: $data->{title}",
        title_link  => "$data->{web_url}",
        color       => $color,
        fields      => \@fields,
      }],
    };

    $event->reply($reply, { slack => $slack });
    $replied++;
  }

  if ($event->was_targeted && !$replied && !$declined_to_reply) {
    $event->reply("Sorry, I couldn't find any merge request matching that.");
  }

  return;
};

listener mention_commit => async sub ($self, $event) {
  my $text = $event->text;

  my $base = $self->url_base;

  unless (
    $text =~ /(^|\s)[-_a-z]+\@[0-9a-f]{7,40}(\W|$)/in
    ||
    $text =~ /\Q$base\E.*?commit/
  ) {
    # No mention, move on.
    return;
  }

  $event->mark_handled if $event->was_targeted;
  my @commits = $text =~ /(?:^|\s)([-_a-z]+\@[0-9a-fA-F]{7,40})(?=\W|$)/gi;

  my %found = $text =~ m{\Q$base\E/(.*?/.*?)(?:/-)?/commit/([0-9a-f]{6,40})}i;

  for my $key (keys %found) {
    my $sha = $found{$key};
    push @commits, "$key\@$sha";
  }

  @commits = uniq @commits;
  my @futures;
  my $replied = 0;
  my $declined_to_reply = 0;

  COMMIT: for my $commit (@commits) {
    my ($proj, $sha) = split /\@/, $commit, 2;

    # $proj might be a shortcut, or it might be an owner/repo string
    my $project_id = $self->is_known_project($proj)
                   ? $self->project_named($proj)
                   : $proj;

    my $url = sprintf("%s/v4/projects/%s/repository/commits/%s",
      $self->api_uri,
      uri_escape($project_id),
      $sha,
    );

    my $res = await $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    unless ($res->is_success) {
      $Logger->log([ "Error fetching commit: %s", $res->as_string ]);
      next COMMIT;
    }

    my $data = $JSON->decode($res->decoded_content);

    if ($self->has_expanded_commit_recently($event, $data->{id})) {
      $event->ephemeral_reply("I've expanded $commit recently here; just scroll up a bit.");
      $declined_to_reply++;
      next COMMIT;
    }

    $self->note_commit_expansion($event, $data->{id});

    my $commit_url = sprintf("%s/%s/commit/%s",
      $self->url_base,
      $project_id,
      $data->{short_id},
    );

    my $reply = "$commit [$data->{author_name}]: $data->{title} ($commit_url)";
    my $slack = sprintf("<%s|%s>: %s [%s]",
      $commit_url,
      $commit,
      $data->{title},
      $data->{author_name},
    );

    my $author_icon = sprintf("https://www.gravatar.com/avatar/%s?s=16",
      md5_hex($data->{author_email}),
    );

    # We don't need to be _quite_ that precise.
    $data->{authored_date} =~ s/\.[0-9]{3}Z$/Z/;

    my $msg = sprintf("commit <%s|%s>\nAuthor: %s\nDate: %s\n\n%s",
      $commit_url,
      $data->{id},
      $data->{author_name},
      $data->{authored_date},
      $data->{message}
    );

    $slack = {
      text        => '',
      attachments => [{
        fallback    => "$data->{author_name}: $data->{short_id} $data->{title} $commit_url",
        text        => $msg,
      }],
    };

    $event->reply($reply, { slack => $slack });
    $replied++;
  }

  if ($event->was_targeted && !$replied && !$declined_to_reply) {
    $event->reply("I couldn't find a commit with that description.");
  }
};

# For every namespace we care about (i.e., $self->relevant_owners), we'll add
# a shortcut that's just the project name, unless it conflicts.
async sub _load_auto_shortcuts ($self) {
  my @conflicts;
  my %names;

  my @futures;

  OWNER: for my $owner ($self->relevant_owners->@*) {
    my $url = sprintf("%s/v4/groups/$owner/projects?simple=1&per_page=100",
      $self->api_uri,
    );

    my $res = await $self->hub->http_get($url,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    unless ($res->is_success) {
      $Logger->log([ "Error fetching projects: %s", $res->as_string ]);
      next OWNER;
    }

    my $data = $JSON->decode($res->decoded_content);

    PROJECT: for my $proj (@$data) {
      my $path = $proj->{path_with_namespace};

      # Sometimes, for reasons I don't fully understand, this returns projects
      # that are not actually owned by the owner.
      my ($p_owner, $name) = split '/', $path;
      next PROJECT unless $p_owner eq $owner;

      next PROJECT if $self->is_known_project($name);

      if ($names{lc $name}) {
        $Logger->log([ "GitLab: ignoring auto-shortcut %s: %s conflicts with %s",
          lc $name,
          $path,
          $names{lc $name},
        ]);

        push @conflicts, lc $name;
        next PROJECT;
      }

      $names{lc $name} = $path;
    }
  }

  $Logger->log("loaded project auto-shortcuts");
  delete $names{$_} for @conflicts;
  return unless keys %names;
  $self->add_shortcuts(%names);
  $self->save_state;

  return;
}

sub _parse_search ($self, $text) {
  my %aliases = (
    by  => 'author',
    for => 'assignee',
  );

  my $fallback = sub ($text_ref) {
    ((my $token), $$text_ref) = split /\s+/, $$text_ref, 2;

    return [ search => $token ];
  };

  my $hunks = String::Switches::parse_colonstrings($text, { fallback => $fallback });

  String::Switches::canonicalize_names($hunks, \%aliases);

  my $error = grep {; @$_ > 2 } @$hunks;

  return if $error;

  return $hunks;
}

sub _icon_for_mr ($self, $mr) {
  # See below, _short_name_for_mr, for this annoying thing. -- rjbs, 2023-10-23
  my ($g_slash_p, $id) = $mr->{web_url} =~ m{([^/]+/[^/]+)/-/merge_requests/([0-9]+)\z};
  my ($group) = split m{/}, $g_slash_p;

  return $self->emoji_for($group) // $self->default_group_emoji;
}

sub _short_name_for_mr ($self, $mr) {
  # So, this is pretty annoying.  The structure we get back for an MR doesn't
  # give us much about the project other than an id, but we do have the web_url
  # field, which is:
  #   https://gitlab.example.com/fastmail/hm/-/merge_requests/5094
  #
  # So, we extract the my-group/my-project and see whether we have a shortcut
  # from (say) repos.yaml.

  my ($g_slash_p, $id) = $mr->{web_url} =~ m{([^/]+/[^/]+)/-/merge_requests/([0-9]+)\z};

  my %shortcuts = $self->project_shortcuts->%*;
  my @found = sort { length $a <=> length $b }
              grep {; $shortcuts{$_} eq $g_slash_p } keys %shortcuts;

  my $name = $found[0] // $g_slash_p;
  return "$name!$id";
}

sub _compile_search ($self, $conds, $event) {
  my $per_page = 50; # I don't really ever intend to change this.

  my $uri = URI->new(
    sprintf "%s/v4/merge_requests/?sort=asc&scope=all&state=opened&per_page=%i",
      $self->api_uri,
      $per_page,
  );

  my $page;
  my $labels;
  my @local_filters;
  my @approval_filters;

  COND: for my $hunk (@$conds) {
    if (@$hunk == 0) {
      # Surely this can't happen!
      $event->error_reply("Your search was too cunning for me to comprehend.");
      return;
    }

    if (@$hunk > 2) {
      # Surely this can't happen!
      $event->error_reply("You had more than one colon after $hunk->[0], which isn't valid.");
      return;
    }

    my ($name, $value) = @$hunk;

    if ($name eq 'page') {
      if (defined $page) {
        $event->error_reply("You gave more than one `page:` condition.");
        return;
      }

      unless ($value =~ /\A[0-9]+\z/ && $value > 0) {
        $event->error_reply("The `page:` condition has to be a positive integer.");
        return;
      }

      $page = $value;

      next COND;
    }

    if ($name eq 'author' or $name eq 'assignee') {
      $name = "$name\_id";

      my $not;

      if ($value eq '*' or $value eq '~') {
        $value = $value eq '*' ? 'Any' : 'None';
      } else {
        $not = $value =~ s/\A!//;
        my $who = $self->resolve_name($value, $event && $event->from_user);
        unless ($who) {
          $event->error_reply("I don't know who $value is.");
          return;
        }

        my $user_id = $self->get_user_preference($who, 'user-id');
        unless ($user_id) {
          $event->error_reply("I don't know the GitLab user id for " .  $who->username . ".");
          return;
        }

        $value = $user_id;
      }

      if ($not) {
        $uri->query_param_append("not[$name]", $value);
      } else {
        $uri->query_param_append($name, $value);
      }

      next COND;
    }

    if ($name eq 'label') {
      # Having "foo" and "None" is nonsensical, but I'm not going to sweat it
      # just now. -- rjbs, 2019-07-23
      if ($value eq '*' or $value eq '~') {
        if (defined $labels) {
          $event->error_reply("You're supplying conflicting `label:` instructions!");
          return;
        }

        $labels = $value eq '*' ? 'Any' : 'None';
      } else {
        if (defined $labels  && ! ref $labels) {
          $event->error_reply("You're supplying conflicting `label:` instructions!");
          return;
        }

        $labels->{$value} = 1;
      }

      $uri->query_param_append($name, $value);
      next COND;
    }

    if ($name eq 'search') {
      $uri->query_param_append($name, $value);
      next COND;
    }

    if ($name eq 'wip') {
      next COND if $value eq 'both';
      unless ($value eq 'yes' or $value eq 'no') {
        $event->error_reply("The value for `wip:` must be yes, no, or both.");
        return;
      }

      $uri->query_param_append($name, $value);
      next COND;
    }

    if ($name eq 'backlogged') {
      next COND if $value eq 'both';
      unless ($value eq 'yes' or $value eq 'no') {
        $event->error_reply("The value for `backlogged:` must be yes, no, or both.");
        return;
      }

      push @local_filters, sub {
        ! grep { fc $_ eq 'backlogged' } $_[0]->{labels}->@*
      };

      next COND;
    }

    if ($name eq 'approved') {
      next COND if $value eq 'both';
      unless ($value eq 'yes' or $value eq 'no') {
        $event->error_reply("The value for `approved:` must be yes, no, or both.");
        return;
      }

      push @approval_filters, $value eq 'yes'
        ? sub {   $_[0]->{_is_approved} }
        : sub { ! $_[0]->{_is_approved} };

      next COND;
    }

    $event->error_reply("Unknown query token: $name");
    return;
  }

  if ($labels) {
    $uri->query_param_append(
      labels => ref $labels
              ? (join q{,}, keys %$labels)
              : $labels
    );
  }

  return {
    uri   => $uri,
    page  => $page // 1,
    local_filters     => \@local_filters,
    approval_filters  => \@approval_filters,
  };
}

async sub _populate_mr_approvals ($self, $mrs) {
  my %mr_by_piid = map {; "$_->{project_id}/$_->{iid}" => $_ } @$mrs;

  my @approval_gets;
  for my $mr (@$mrs) {
    next if defined $mr->{_is_approved};

    my $url = sprintf("%s/v4/projects/%s/merge_requests/%d/approvals",
      $self->api_uri,
      $mr->{project_id},
      $mr->{iid},
    );

    push @approval_gets, $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
    );
  }

  # Maybe they're all already populated!
  return unless @approval_gets;

  my @res_f = await Future->wait_all(@approval_gets);

  for my $res_f (@res_f) {
    my $res = $res_f->get;
    my $approval_data = $JSON->decode($res->decoded_content);

    # This is absurd.  The docs on getting approvals show that the id,
    # project id, and iid are included in the response.
    # (See https://docs.gitlab.com/ee/api/merge_request_approvals.html#get-configuration-1 )
    # ...but they are not.  So, rather than screw around with decorating the
    # future in @approval_gets, we'll parse project and MR id out of the
    # response's request's URI.  But this is absurd. -- rjbs, 2021-11-28
    my ($project_id, $iid) = $res->request->uri =~ m{
      /projects/([0-9]+)
      /merge_requests/([0-9]+)/
    }x;

    next unless $project_id;
    my $mr = $mr_by_piid{ "$project_id/$iid" };
    my $approval_count = $approval_data->{approved_by} && $approval_data->{approved_by}->@*;
    $mr->{_is_approved} = $approval_count > 0 ? 1 : 0;
  }

  return;
}

async sub _queue_produce_page_list ($self, $queue_arg) {
  # Don't confuse API page with display page!  The API page is the page of 20
  # that we get from the API.  The display page is the page of 10 that we will
  # display to the user. -- rjbs, 2021-11-28
  my $display_page = $queue_arg->{display_page} // 1;
  my $per_page     = $queue_arg->{per_page}     // 10;
  my $api_page     = $queue_arg->{api_page}     // 1;

  my @local_filters    = ($queue_arg->{local_filters}    // [])->@*;
  my @approval_filters = ($queue_arg->{approval_filters} // [])->@*;

  my $event   = $queue_arg->{event};

  my @mrs;
  my $saw_last_page;

  until (@mrs >= $display_page*$per_page || $saw_last_page) {
    my $uri  = $queue_arg->{query_uri}->clone;
    $uri->query_param(page => $api_page);

    $Logger->log("GitLab GET: $uri");

    my $res = await $self->hub->http_get(
      $uri,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    unless ($res->is_success) {
      $Logger->log([ "error fetching merge requests: %s", $res->as_string ]);
      Synergy::X->throw_public("Something went wrong fetching merge requests.");
    }

    my $mr_batch = $JSON->decode($res->decoded_content);

    unless (@$mr_batch) {
      $event->error_reply("No results!");
      return;
    }

    my $zero = ($display_page-1) * $per_page;

    if ($zero > $#$mr_batch) {
      $event->error_reply("You've gone past the last page!");
      return;
    }

    $saw_last_page = 1
      if ($res->header('x-page') // -1) == ($res->header('x-total-pages') // -2);

    if (@approval_filters) {
      # If we need to have approvals before postfilters, we will get them now.
      await $self->_populate_mr_approvals($mr_batch);

      @$mr_batch = grep {;
        my $datum = $_;
        all { $_->($datum) } @approval_filters;
      } @$mr_batch;
    }

    if (@$mr_batch) {
      # Stupid, inefficient, good enough. -- rjbs, 2019-07-29
      @$mr_batch = grep {;
        my $datum = $_;
        all { $_->($datum) } @local_filters;
      } @$mr_batch;
    }

    if (!@approval_filters) {
      # We didn't have to do this before local filters, so we'll do it now.
      await $self->_populate_mr_approvals($mr_batch);
    }

    push @mrs, @$mr_batch;

    $api_page++;
  }

  my $zero = ($display_page-1) * $per_page;
  my @page = grep {; $_ } @mrs[ $zero .. $zero+$per_page-1 ];

  return {
    page_number => $display_page,
    first_index => $zero + 1,
    last_index  => $zero + @page,
    mrs         => \@page,
  };
}

async sub _page_for_search_string ($self, $text, $event, $arg = undef) {
  my $conds = $self->_parse_search($text);

  unless ($conds) {
    Synergy::X->throw_public("I didn't understand your search.");
  }

  my $query = $self->_compile_search($conds, $event);

  unless ($query) {
    # if _compile_search returned undef, we should have already done an error
    # reply, so we can just return here
    return;
  }

  # We want N items, where N is the per-display-page value, always 10.
  # We want the Pth page.  This means items from index (P-1)*10 to P*10-1.
  #
  # If all items will be client-side approved, we need to fetch at least P*10
  # items, filter those, and see whether we need more.

  my $page = await $self->_queue_produce_page_list({
    event     => $event,
    query_uri => $query->{uri},
    display_page  => $query->{page},
    local_filters     => $query->{local_filters},
    approval_filters  => $query->{approval_filters},

    ($arg && $arg->{per_page} ? (per_page => $arg->{per_page}) : ()),
  });
}

async sub _handle_mr_search_string ($self, $text, $event) {
  my $page = await $self->_page_for_search_string($text, $event);

  return unless defined $page;

  my $header = sprintf "Results, page %s (items %s .. %s):",
    $page->{page_number},
    $page->{first_index},
    $page->{last_index};

  my $text  = $header;
  my $slack = "*$header*";

  for my $mr ($page->{mrs}->@*) {
    my $icons = q{};
    if ($mr->{work_in_progress}) {
      $icons .= "🚧";
      $mr->{title} =~ s/^Draft:?\s+//i;
    }

    $icons .= "✅" if $mr->{_is_approved};
    $icons .= "👍" if $mr->{upvotes};
    $icons .= "👎" if $mr->{downvotes};

    $icons .= " " if length $icons;

    my $short_name = $self->_short_name_for_mr($mr);

    $text  .= "\n* $icons $short_name $mr->{title}";
    $slack .= sprintf "\n%s *<%s|%s>* %s%s — _(%s)_",
      $self->_icon_for_mr($mr),
      $mr->{web_url},
      $short_name,
      $icons,
      ($mr->{title} =~ s/^Draft: //r),
      $mr->{author}{username}
        . ($mr->{assignee} ? " → $mr->{assignee}{username}" : ", unassigned");

    $slack .= sprintf "— {%s}", join q{, }, $mr->{labels}->@*
      if $mr->{labels} && $mr->{labels}->@*;
  }

  return await $event->reply($text, { slack => $slack });
}

async sub mr_report ($self, $who, $arg = {}) {
  my @futures;

  my $user_id = $self->get_user_preference($who, 'user-id');

  return unless $user_id;

  my $uri = URI->new(sprintf '%s/dashboard/merge_requests?scope=all&state=opened',
    $self->url_base,
  );

  my $username = $who->username;

  ### These categories copied from the shortcuts for "mrs SHORTCUT":
  #
  # todo    => 'by:!me for:me backlogged:no',
  # ready   => 'by:me for:me approved:yes',
  # waiting => 'by:me for:!me for:* backlogged:no',
  #
  # The third element in the arrayrefs below is URI query parameters to put on
  # the link to human-facing GitLab for these.
  my @to_report = (
    [
      "awaiting your review",
      "by:!$username for:$username backlogged:no",
      { assignee_username => $username, 'not[author_username]' => $username },
    ],
    [
      "approved and with you",
      "by:$username for:$username approved:yes",
      {
        assignee_username => $username,
        author_username   => $username,
        'approved_by_usernames[]', 'Any'
      },
    ],
    [
      "awaiting review by someone else",
      "by:$username for:!$username backlogged:no",
      { 'not[assignee_username]' => $username, 'author_username' => $username },
    ],
  );

  my @text;
  my @slack;

  for my $pair (@to_report) {
    my ($desc, $search, $link_params) = @$pair;

    # We don't have an $event, which would be a problem if anything in here was
    # going to hit an error, which it shouldn't.  Still, we should replace
    # event with something better in the future, like "who".  We could
    # eliminate using $event->error_reply by using Synergy::X.
    # -- rjbs, 2023-12-01
    my $page = await $self->_page_for_search_string(
      $search,
      undef, # should be $event
      { per_page => 26 },
    );

    next unless $page && $page->{last_index};

    my $link = $uri->clone;
    $link->query_param($_ => $link_params->{$_}) for keys %$link_params;

    push @text, sprintf "\N{LOWER LEFT CRAYON} Merge requests %s: %i",
      $desc,
      $page->{last_index} == 26 ? '25+' : $page->{last_index};

    push @slack, sprintf "\N{LOWER LEFT CRAYON} Merge requests <%s|%s>: %i",
      $link,
      $desc,
      $page->{last_index} == 26 ? '25+' : $page->{last_index};
  }

  return [
    (join qq{\n}, @text),
    {
      slack => join qq{\n}, @slack
    },
  ];
}

async sub post_gitlab_snippet ($self, $payload) {
  my $res = await $self->hub->http_client->do_request(
    method => 'POST',
    uri    => $self->api_uri . '/v4/snippets',
    headers => {
      'PRIVATE-TOKEN' => $self->api_token,
    },

    content_type => 'application/json',
    content      => encode_json($payload),
  );

  unless ($res->is_success) {
    die "error creating snippet on GitLab: " . $res->as_string;
  }

  my $json = $res->decoded_content(charset => undef);
  my $snippet_metadata = decode_json($json);
  return $snippet_metadata->{web_url};
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  validator => async sub ($self, $value, @) {
    return $value if $value =~ /\A[0-9]+\z/;
    return (undef, "Your user-id must be a positive integer.")
  },
  default   => undef,
);

1;
