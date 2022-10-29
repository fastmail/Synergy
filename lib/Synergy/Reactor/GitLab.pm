use v5.34.0;
use warnings;
use utf8;
package Synergy::Reactor::GitLab;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences',
     'Synergy::Role::DeduplicatesExpandos' => {
       expandos => [qw( mr commit )],
     };

use experimental qw(lexical_subs signatures);
use namespace::clean;
use DateTime::Format::ISO8601;
use Digest::MD5 qw(md5_hex);
use Future 0.36;  # for ->retain
use IO::Async::Timer::Periodic;
use JSON::MaybeXS;
use Lingua::EN::Inflect qw(PL_N PL_V);
use List::Util qw(all uniq);
use MIME::Base64;
use POSIX qw(ceil);
use Synergy::Logger '$Logger';
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
    is_known_project => 'exists',
    project_named    => 'get',
    all_shortcuts    => 'keys',
    add_shortcuts    => 'set',
  }
);

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

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    my $repo_state = $state->{repos} // {};
    $self->_set_shortcuts($repo_state);
  }
};

sub start ($self) {
  $self->add_shortcuts($self->custom_project_shortcuts->%*);

  my $timer = IO::Async::Timer::Countdown->new(
    delay => 60,
    notifier_name => 'gitlab-load-shortcuts',
    remove_on_expire => 1,
    on_expire => sub {
      $Logger->log("loading shortcuts from GitLab");
      $self->_load_auto_shortcuts;
    }
  );

  $self->hub->loop->add($timer->start);
}

sub state ($self) {
  return {
    repos => $self->project_shortcuts,
  };
}

my $MRS_HELP = <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg;
The *mrsearch* command searches merge requests in GitLab.  You can pass in a
list of colon-separated pairs like *for:me* to limit the results, or just words
to search for.  Here are the arguments you can pass:

• *for:`USER`*: MRs assigned to the named user; `*` for "assigned to anybody"
or `~` for "assigned to nobody"
• *by:`USER`*: MRs authored by the named user
• *approved:`{yes,no,both}`*: only MRs that are (or are not) approved to merge
• *label:`LABEL`*: MRs with the given label; `*` for "has a label at all" or
`~` for "has no labels"
• *backlogged:`{yes,no,both}`*: whether or not to include MRs with the "backlogged" label
• *wip:`{yes,no,both}`*: whether or not to include works in progress

Alternatively, you can just pass a single argument as a shortcut:
• *todo*: MRs that are waiting for your review
• *waiting*: MRs you sent out for review
• *ready*: MRs that you wrote, are assigned to you, and are approved
EOH

sub listener_specs {
  return (
    {
      name      => 'r?',
      method    => 'handle_r_hook',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text eq 'r?' },
      help_entries => [
        { title => 'r?',
          text  => 'This is short for `mrsearch for:me backlogged:no` -- in other words, "what can I act on right now?".'
        },
      ],
    },
    {
      name      => 'mr-search',
      method    => 'handle_mr_search',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /^mrs(?:earch)?(?:\z|\s+)/i },
      help_entries => [
        {
          title => 'mrs',
          text  => $MRS_HELP,
        },
        {
          title => 'mrsearch',
          text  => $MRS_HELP,
        },
      ],
    },
    {
      name => 'mention-mr',
      method => 'handle_merge_request',
      predicate => sub ($self, $e) {
        return if $e->text =~ /^\s*\@?bort/i;
        return 1 if $e->text =~ /\b[-_a-z]+!\d+(\W|$)/in;

        my $base = $self->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?merge_requests/;
      },
      allow_empty_help => 1,
    },
    {
      name => 'mention-commit',
      method => 'handle_commit',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /(^|\s)[-_a-z]+\@[0-9a-f]{7,40}(\W|$)/in;

        state $base = $self->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?commit/;
      },
      allow_empty_help => 1,
    },
  );
}

# For every namespace we care about (i.e., $self->relevant_owners), we'll add
# a shortcut that's just the project name, unless it conflicts.
sub _load_auto_shortcuts ($self) {
  my @conflicts;
  my %names;

  my @futures;

  for my $owner ($self->relevant_owners->@*) {
    my $url = sprintf("%s/v4/groups/$owner/projects?simple=1&per_page=100",
      $self->api_uri,
    );

    my $http_future = $self->hub->http_get($url,
      'PRIVATE-TOKEN' => $self->api_token,
    );
    push @futures, $http_future;

    $http_future->on_done(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);
        return;
      }

      my $data = $JSON->decode($res->decoded_content);

      for my $proj (@$data) {
        my $path = $proj->{path_with_namespace};

        # Sometimes, for reasons I don't fully understand, this returns projects
        # that are not actually owned by the owner.
        my ($p_owner, $name) = split '/', $path;
        next unless $p_owner eq $owner;

        next if $self->is_known_project($name);

        if ($names{$name}) {
          $Logger->log([ "GitLab: ignoring auto-shorcut %s: %s conflicts with %s",
            $name,
            $path,
            $names{$name},
          ]);

          push @conflicts, $name;
          next;
        }

        $names{$name} = $path;
      }
    });
  }

  Future->wait_all(@futures)->on_ready(sub {
    $Logger->log("loaded project auto-shortcuts");
    delete $names{$_} for @conflicts;
    return unless keys %names;
    $self->add_shortcuts(%names);
    $self->save_state;
  })->retain;
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

  my $hunks = Synergy::Util::parse_colonstrings($text, { fallback => $fallback });

  Synergy::Util::canonicalize_names($hunks, \%aliases);

  my $error = grep {; @$_ > 2 } @$hunks;

  return if $error;

  return $hunks;
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

sub handle_r_hook ($self, $event) {
  $event->mark_handled;
  $self->_handle_mr_search_string("for:me backlogged:no", $event);
}

my %MR_SHORTCUT = (
  todo    => 'by:!me for:me backlogged:no',
  ready   => 'by:me for:me approved:yes',
  waiting => 'by:me for:!me for:* backlogged:no',
);

sub handle_mr_search ($self, $event) {
  $event->mark_handled;
  my $rest = $event->text =~ s/\Amrs(?:earch)?\s*//ir;

  unless (length $rest) {
    return $event->reply($MRS_HELP);
  }

  # Fun fact: we document only "mrs todo" but "mrs todo x:y" works, 99% so that
  # you can say "mrs todo page:2" -- rjbs, 2021-11-29
  if ($rest =~ s/\A([a-z]\S+)(\s|$)//i) {
    $rest = ($MR_SHORTCUT{$1} // $1) . " $rest";
    $rest =~ s/\s+$//;
  }

  $self->_handle_mr_search_string($rest, $event);
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
        my $who = $self->resolve_name($value, $event->from_user);
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

sub _populate_mr_approvals ($self, $arg, $mrs) {
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
  return Future->done($arg, $mrs) unless @approval_gets;

  Future->wait_all(@approval_gets)->then(sub (@res_f) {
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

    Future->done($arg, $mrs);
  });
}

sub _queue_produce_page_list ($self, $queue_arg) {
  # Don't confuse API page with display page!  The API page is the page of 20
  # that we get from the API.  The display page is the page of 10 that we will
  # display to the user. -- rjbs, 2021-11-28
  my $display_page = $queue_arg->{display_page} // 1;
  my $api_page     = $queue_arg->{api_page}     // 1;
  my $uri  = $queue_arg->{query_uri}->clone;
  $uri->query_param(page => $api_page);

  my @local_filters    = ($queue_arg->{local_filters}    // [])->@*;
  my @approval_filters = ($queue_arg->{approval_filters} // [])->@*;
  my @starting_list    = ($queue_arg->{starting_list}    // [])->@*;

  $Logger->log("GitLab GET: $uri");

  my $event   = $queue_arg->{event};
  my $on_done = $queue_arg->{on_done};

  my $http_future = $self->hub->http_get(
    $uri,
    'PRIVATE-TOKEN' => $self->api_token,
  );

  $http_future->then(sub ($res) {
    unless ($res->is_success) {
      $Logger->log([ "Error: %s", $res->as_string ]);
      Future->fail("response no good");
    }

    my $data = $JSON->decode($res->decoded_content);

    unless (@$data) {
      $event->error_reply("No results!");
      return Future->fail('no result'); # Failure seems wrong.
    }

    my $zero = ($display_page-1) * 10;

    if ($zero > $#$data) {
      $event->error_reply("You've gone past the last page!");
      return Future->fail('past last page'); # Failure seems wrong.
    }

    my $is_last_page = ($res->header('x-page')        // -1)
                    == ($res->header('x-total-pages') // -2);

    my %arg = (
      is_last_page  => $is_last_page,
      starting_list => \@starting_list,
    );

    Future->done(\%arg, $data);
  })->then(sub ($arg, $mrs) {
    # If we need to have approvals before postfilters, we will get them now.
    return Future->done($arg, $mrs) unless @approval_filters;

    $self->_populate_mr_approvals($arg, $mrs)->then(sub ($arg, $mrs) {
      @$mrs = grep {;
        my $datum = $_;
        all { $_->($datum) } @approval_filters;
      } @$mrs;

      Future->done($arg, $mrs);
    });
  })->then(sub ($arg, $mrs) {
    if (@$mrs) {
      # Stupid, inefficient, good enough. -- rjbs, 2019-07-29
      @$mrs = grep {;
        my $datum = $_;
        all { $_->($datum) } @local_filters;
      } @$mrs;
    }

    my @list = (
      $arg->{starting_list}->@*,
      @$mrs,
    );

    return @approval_filters
      ? Future->done($arg, \@list)
      : $self->_populate_mr_approvals($arg, \@list);
  })->then(sub ($arg, $mrs) {
    if (@$mrs >= $display_page*10 || $arg->{is_last_page}) {
      my $zero = ($display_page-1) * 10;
      my @page = grep {; $_ } $mrs->@[ $zero .. $zero+9 ];

      my $header = sprintf "Results, page %s (items %s .. %s):",
        $display_page,
        $zero + 1,
        $zero + @page;

      return $on_done->($header, \@page);
    }

    return $self->_queue_produce_page_list({
      %$queue_arg,
      starting_list => $mrs,
      api_page      => $api_page + 1,
    });
  })->else(sub ($err, @rest) {
    # handle known-fine cases
    return Future->done if $err eq 'no result' || $err eq 'past last page';

    $Logger->log([ "ERROR: %s", [$err, @rest] ]);
    Future->fail($err, @rest);
  });
}

sub _handle_mr_search_string ($self, $text, $event) {
  my $conds = $self->_parse_search($text);

  unless ($conds) {
    return $event->error_reply("I didn't understand your search.");
  }

  my $query = $self->_compile_search($conds, $event);

  unless ($query) {
    # if _compile_search returned undef, we should have already done an error
    # reply, so we can just return here
    return Future->done;
  }

  my $reply_with_list = sub ($header, $mrs) {
    my $text  = $header;
    my $slack = "*$header*";

    for my $mr (@$mrs) {
      my $icons = q{};
      if ($mr->{work_in_progress}) {
        $icons .= "🚧";
        $mr->{title} =~ s/^wip:?\s+//i;
      }

      $icons .= "✅" if $mr->{_is_approved};
      $icons .= "👍" if $mr->{upvotes};
      $icons .= "👎" if $mr->{downvotes};

      $icons .= " " if length $icons;

      $text  .= "\n* $icons $mr->{title}";
      $slack .= sprintf "\n*<%s|%s>* %s%s — _(%s)_",
        $mr->{web_url},
        $self->_short_name_for_mr($mr),
        $icons,
        $mr->{title},
        $mr->{author}{username}
          . ($mr->{assignee} ? " → $mr->{assignee}{username}" : ", unassigned");

      $slack .= sprintf "— {%s}", join q{, }, $mr->{labels}->@*
        if $mr->{labels} && $mr->{labels}->@*;
    }

    $event->reply($text, { slack => $slack });
    return Future->done;
  };

  # We want N items, where N is the per-display-page value, always 10.
  # We want the Pth page.  This means items from index (P-1)*10 to P*10-1.
  #
  # If all items will be client-side approved, we need to fetch at least P*10
  # items, filter those, and see whether we need more.

  $self->_queue_produce_page_list({
    event     => $event,
    on_done   => $reply_with_list,
    query_uri => $query->{uri},
    display_page  => $query->{page},
    local_filters     => $query->{local_filters},
    approval_filters  => $query->{approval_filters},
  })->retain;
}

sub handle_merge_request ($self, $event) {
  my $text = $event->text;

  my @mrs = $text =~ /\b([-_a-z]+!\d+)(?=\W|$)/gi;

  $text =~ s/\Q$_// for @mrs;

  $event->mark_handled if $event->was_targeted && $text !~ /\S/;

  my $base = $self->url_base;
  my @found = $event->text =~ m{\Q$base\E/(.*?/.*?)(?:/-)?/merge_requests/([0-9]+)}g;

  while (my ($key, $num) = splice @found, 0, 2) {
    push @mrs, "$key!$num";
  }

  @mrs = uniq @mrs;
  my @futures;
  my $replied = 0;
  my $declined_to_reply = 0;

  for my $mr (@mrs) {
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

    my $http_future = Future->wait_all($mr_get, $approval_get);
    push @futures, $http_future;

    $http_future->on_done(sub ($mr_f, $approval_f) {
      my $mr_res = $mr_f->get;
      unless ($mr_res->is_success) {
        $Logger->log([ "Error: %s", $mr_res->as_string ]);
        return;
      }

      my $approval_res = $approval_f->get;
      unless ($approval_res->is_success) {
        $Logger->log([ "Error: %s", $approval_res->as_string ]);
        return;
      }

      my $data = $JSON->decode($mr_res->decoded_content);
      my $approval_data = $JSON->decode($approval_res->decoded_content);

      my $is_approved = $approval_data->{approved};

      if ($self->has_expanded_mr_recently($event, $data->{id})) {
        $declined_to_reply++;
        return;
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
    });
  }

  Future->wait_all(@futures)->on_done(sub {
    return if $replied;

    return $event->ephemeral_reply("I've expanded that recently here; just scroll up a bit.")
      if $declined_to_reply;

    return unless $event->was_targeted;

    $event->reply("Sorry, I couldn't find any merge request matching that.");
  })->retain;
}

sub handle_commit ($self, $event) {
  $event->mark_handled if $event->was_targeted;
  my @commits = $event->text =~ /(?:^|\s)([-_a-z]+\@[0-9a-fA-F]{7,40})(?=\W|$)/gi;

  state $base = $self->url_base;
  my %found = $event->text =~ m{\Q$base\E/(.*?/.*?)(?:/-)?/commit/([0-9a-f]{6,40})}i;

  for my $key (keys %found) {
    my $sha = $found{$key};
    push @commits, "$key\@$sha";
  }

  @commits = uniq @commits;
  my @futures;
  my $replied = 0;
  my $declined_to_reply = 0;

  for my $commit (@commits) {
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

    my $http_future = $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
    );
    push @futures, $http_future;

    $http_future->on_done(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);
        return;
      }

      my $data = $JSON->decode($res->decoded_content);

      if ($self->has_expanded_commit_recently($event, $data->{id})) {
        $declined_to_reply++;
        return;
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
    });
  }

  Future->wait_all(@futures)->on_done(sub {
    return if $replied;

    return $event->ephemeral_reply("I've expanded that recently here; just scroll up a bit.")
      if $declined_to_reply;

    return unless $event->was_targeted;

    $event->reply("I couldn't find a commit with that description.");
  })->retain;
}

sub mr_report ($self, $who, $arg = {}) {
  my @futures;

  my $user_id = $self->get_user_preference($who, 'user-id');

  return unless $user_id;

  for my $pair (
    # TODO: Cope with pagination for real. -- rjbs, 2018-08-17
    [ filed => sprintf("%s/v4/merge_requests/?scope=all&author_id=%s&state=opened&per_page=100",
        $self->api_uri, $user_id) ],
    [ assigned => sprintf("%s/v4/merge_requests/?scope=all&assignee_id=%s&state=opened&per_page=100",
        $self->api_uri, $user_id) ],
  ) {
    my ($type, $uri) = @$pair;

    my $http_future = $self->hub->http_get(
      $uri,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    push @futures, $http_future->then(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);

        return Future->done($type => undef);
      }

      my $data = $JSON->decode($res->decoded_content);
      for my $mr (@$data) {
        $mr->{_isBacklogged} = 1
          if grep {; lc $_ eq 'backlogged' } $mr->{labels}->@*;

        $mr->{_isSelfAssigned} = 1
          if $mr->{assignee} && $mr->{assignee}{id} == $user_id
                             && $mr->{author}{id}   == $user_id;
      }

      return Future->done($type => $data);
    });
  }

  Future->wait_all(@futures)->then(sub (@futures) {
    my %result = map {; $_->get } @futures;

    if (! defined $result{assigned} || ! defined $result{filed}) {
      return Future->new->done(
        [ "Something when wrong when trying to get merge request data." ]
      );
    }

    my @selfies  = grep {; ! $_->{_isBacklogged} &&   $_->{_isSelfAssigned} }
                   $result{filed}->@*;
    my @filed    = grep {; ! $_->{_isBacklogged} && ! $_->{_isSelfAssigned} }
                   $result{filed}->@*;
    my @assigned = grep {; ! $_->{_isBacklogged} && ! $_->{_isSelfAssigned} }
                   $result{assigned}->@*;

    return Future->done unless @filed || @assigned || @selfies;

    my $wipstr = sub ($mrs) {
      my $wip = grep {; $_->{title} =~ /^wip:/i } @$mrs;
      return $wip
        ? (sprintf ' (of which %i %s WIP)', $wip, PL_V('is', $wip))
        : '';
    };

    my $link = sub ($author, $assignee) {
      return sprintf '<%s/dashboard/merge_requests?scope=all&state=opened%s%s|GL>',
        $self->url_base,
        (defined $author   ? "&author_username=$author"     : ''),
        (defined $assignee ? "&assignee_username=$assignee" : ''),
    };

    my @plain;
    my @slack;

    if (@filed) {
      push @plain, sprintf "\N{LOWER LEFT CRAYON} Merge %s waiting on others: %i%s",
        PL_N('request', 0+@filed), 0+@filed, $wipstr->(\@filed);

      my $url = $link->($who->username, undef);
      push @slack, $plain[-1] =~ s/ / $url /r;
    }

    if (@assigned) {
      my $wip = grep {; $_->{title} =~ /^wip:/i } @filed;
      push @plain, sprintf "\N{LOWER LEFT CRAYON} Merge %s to review: %i%s",
        PL_N('request', 0+@assigned), 0+@assigned, $wipstr->(\@assigned);

      my $url = $link->(undef, $who->username);
      push @slack, $plain[-1] =~ s/ / $url /r;
    }

    if (@selfies) {
      my $wip = grep {; $_->{title} =~ /^wip:/i } @filed;
      push @plain, sprintf "\N{LOWER LEFT CRAYON} Self-assigned merge %s: %i%s",
        PL_N('request', 0+@selfies), 0+@selfies, $wipstr->(\@selfies);

      my $url = $link->($who->username, $who->username);
      push @slack, $plain[-1] =~ s/ / $url /r;
    }

    return Future->done([
      (join qq{\n}, @plain),
      {
        slack => (join qq{\n}, @slack),
      }
    ]);
  });
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  validator => sub ($self, $value, @) {
    return $value if $value =~ /\A[0-9]+\z/;
    return (undef, "Your user-id must be a positive integer.")
  },
  default   => undef,
);

1;
