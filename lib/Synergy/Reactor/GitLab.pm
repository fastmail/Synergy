use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::GitLab;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;
use DateTime::Format::ISO8601;
use DateTimeX::Format::Ago;
use Digest::MD5 qw(md5_hex);
use Future 0.36;  # for ->retain
use JSON 2 ();
use Lingua::EN::Inflect qw(PL_N PL_V);
use List::Util qw(uniq);
use MIME::Base64;
use POSIX qw(ceil);
use Synergy::Logger '$Logger';
use URI::Escape;
use YAML::XS;

my $JSON = JSON->new->utf8->canonical;

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

has project_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has user_config => (
  is => 'ro',
  isa => 'HashRef',
  traits  => [ 'Hash' ],
  lazy => 1,
  default => sub { {} },
  writer => '_set_user_config',
  handles => {
    set_user   => 'set',
    user_pairs => 'kv',
  },
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

has relevant_owners => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub { [] },
);

has _recent_mr_expansions => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  default => sub { {} },
  handles => {
    has_expanded_mr_recently => 'exists',
    note_mr_expansion        => 'set',
    remove_mr_expansion      => 'delete',
    recent_mr_expansions     => 'keys',
    mr_expansion_for         => 'get',
  },
);

has _recent_commit_expansions => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  default => sub { {} },
  handles => {
    has_expanded_commit_recently => 'exists',
    note_commit_expansion        => 'set',
    remove_commit_expansion      => 'delete',
    recent_commit_expansions     => 'keys',
    commit_expansion_for         => 'get',
  },
);

# We'll only keep records of expansions for 5m or so.
has expansion_record_reaper => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return IO::Async::Timer::Periodic->new(
      interval => 30,
      on_tick  => sub {
        my $then = time - (60 * 5);

        for my $key ($self->recent_mr_expansions) {
          my $ts = $self->mr_expansion_for($key);
          $self->remove_mr_expansion($key) if $ts lt $then;
        }

        for my $key ($self->recent_commit_expansions) {
          my $ts = $self->commit_expansion_for($key);
          $self->remove_commit_expansion($key) if $ts lt $then;
        }
      },
    );
  }
);

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    # Backcompat: the user config used to be the only thing in state, and it's
    # not any more. This can go away eventually -- michael, 2018-08-13
    my $user_config = exists $state->{users} ? $state->{users} : $state;
    $self->_set_user_config($user_config);

    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }

    for my $pair ($self->user_pairs) {
      my ($username, $uconfig) = @$pair;
      $self->hub->user_directory->reload_user($username, $uconfig);
    }

    my $repo_state = $state->{repos} // {};
    $self->_set_shortcuts($repo_state);
  }
};

sub start ($self) {
  my $timer = IO::Async::Timer::Countdown->new(
    delay => 60,
    on_expire => sub {
      $Logger->log("fetching user config from GitLab");

      my $f = $self->_reload_all;
      $f->on_done(sub {
        my @errors = map {; $_->failure} $f->failed_futures;
        $Logger->log([
          "error doing initial user config load from GitLab: %s",
          \@errors,
        ]);
      });

      my $f2 = $self->_reload_repos;
      $f2->on_fail(sub ($err) {
        $Logger->log([
          "error doing initial repo load from GitLab: %s",
          $err
        ]);
      });
    }
  );

  $timer->start;
  $self->hub->loop->add($timer);
  $self->hub->loop->add($self->expansion_record_reaper->start);
}

sub state ($self) {
  return {
    users => $self->user_config,
    repos => $self->project_shortcuts,
    preferences => $self->user_preferences,
  };
}

sub listener_specs {
  return (
    {
      name      => 'reload',
      method    => 'handle_reload',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted &&
        $e->text =~ /^reload\s+(?!shortcuts)/in;
      },
    },
    {
      name      => 'mr-search',
      method    => 'handle_mr_search',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted &&
        $e->text =~ /^mrsearch\s+/i;
      },
    },
    {
      name => 'mention-mr',
      method => 'handle_merge_request',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /(^|\s)[-_a-z]+!\d+(\W|$)/in;

        my $base = $self->reactor->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?merge_requests/;
      }
    },
    {
      name => 'mention-commit',
      method => 'handle_commit',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /(^|\s)[-_a-z]+\@[0-9a-f]{7,40}(\W|$)/in;

        state $base = $self->reactor->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?commit/;
      }
    },
  );
}

sub handle_reload ($self, $event) {
  $event->mark_handled;

  return $event->error_reply("Sorry, I don't know who you are.")
    unless $event->from_user;

  my $text = $event->text;
  my ($what) = $text =~ /^\s*reload\s+(.*)/i;
  $what &&= lc $what;

  $what =~ s/^\s*|\s*$//g;

  return $self->handle_my_config($event)  if $what eq 'my config';
  return $self->handle_all_config($event) if $what eq 'all user config';
  return $self->handle_repos($event)      if $what eq 'repos';

  return $event->error_reply("I don't know how to reload <$what>");
}

sub handle_my_config ($self, $event) {
  my $username = $event->from_user->username;
  my $f = $self->_update_user_config($username);

  $f->on_fail(sub ($err) { $event->reply("error reloading config: $err") });
  $f->on_done(sub { $event->reply("your configuration has been reloaded") });
}

sub handle_all_config ($self, $event) {
  return $event->reply("Sorry, only the master user can do that")
    unless $event->from_user->is_master;

  my $f = $self->_reload_all;
  $f->on_done(sub {
    if ($f->ready_futures == $f->done_futures) {
      return $event->reply("user config reload");
    }

    my @errors = map {; $_->failure } $f->failed_futures;
    my $who = join ', ', sort @errors;
    return $event->reply("encounted errors while reloading following users: $who");
  });
}

sub handle_repos ($self, $event) {
  my $f = $self->_reload_repos;
  $f->on_done(sub { return $event->reply("repo config reloaded") });
  $f->on_fail(sub ($err) {
    return $event->reply("encounter errors reloading repos: $err");
  });
}

sub _reload_all ($self) {
  my (@errors, @futures);

  for my $username ($self->hub->user_directory->usernames) {
    my $f = $self->_update_user_config($username);
    push @futures, $f;
  }

  return Future->wait_all(@futures);
}

sub _update_user_config ($self, $username) {
  my $url = sprintf("%s/v4/projects/%s/repository/files/%s.yaml?ref=master",
    $self->api_uri,
    $self->project_id,
    $username,
  );

  my $http_future = $self->hub->http_get(
    $url,
    'PRIVATE-TOKEN' => $self->api_token,
    async => 1,
  );

  my $ret_future = $self->loop->new_future;

  $http_future->on_done(sub ($res) {
    unless ($res->is_success) {
      if ($res->code == 404) {
        $self->hub->user_directory->reload_user($username, {});
        return $ret_future->fail("$username: no config in git");
      }

      $Logger->log([ "Error: %s", $res->as_string ]);
      return $ret_future->fail("$username: error retrieving config");
    }

    my $content = eval {
      decode_base64( $JSON->decode( $res->decoded_content )->{content} );
    };

    return $ret_future->fail("$username: error with GitLab response")
      unless $content;

    my $uconfig = eval { YAML::XS::Load($content) };
    return $ret_future->fail("$username: error with YAML in config")
      unless $uconfig;

    $self->hub->user_directory->reload_user($username, $uconfig);
    $self->hub->load_preferences_from_user($username);
    $self->set_user($username => $uconfig);
    $self->save_state;

    $ret_future->done;
  });

  return $ret_future;
}

sub _reload_repos ($self) {
  my $url = sprintf("%s/v4/projects/%s/repository/files/repos.yaml?ref=master",
    $self->api_uri,
    $self->project_id,
  );

  my $ret_future = $self->loop->new_future;
  my $http_future = $self->hub->http_get(
    $url,
    'PRIVATE-TOKEN' => $self->api_token,
    async => 1,
  );

  $http_future->on_done(sub ($http_res) {
    unless ($http_res->is_success) {
      $Logger->log([ "Error: %s", $http_res->as_string ]);
      return $ret_future->fail('error retrieving repo config');
    }

    my $content = eval {
      decode_base64( $JSON->decode( $http_res->decoded_content )->{content} );
    };

    return $ret_future->fail('error with GitLab response') unless $content;

    my $repos = eval { YAML::XS::Load($content) };
    return $ret_future->fail('error with YAML in config') unless $repos;

    $self->add_shortcuts(%$repos);
    $self->_load_auto_shortcuts;
    $self->save_state;

    $ret_future->done;
  });

  return $ret_future;
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
      async => 1
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
  })->retain;
}

sub _key_for_gitlab_data ($self, $event, $data) {
  # Not using $event->source_identifier here because we don't care _who_
  # triggered the expansion. -- michael, 2019-02-05
  return join(';',
    $data->{id},
    $event->from_channel->name,
    $event->conversation_address
  );
}

sub _parse_search ($self, $text) {
  my $fallback = sub ($text_ref) {
    ((my $token), $$text_ref) = split /\s+/, $$text_ref, 2;

    return [ search => $token ];
  };

  my $hunks = Synergy::Util::parse_colonstrings($text, { fallback => $fallback });

  my $error = grep {; @$_ > 2 } @$hunks;

  return if $error;

  return $hunks;
}

sub handle_mr_search ($self, $event) {
  $event->mark_handled;
  my $rest = $event->text =~ s/\Amrsearch\s+//ir;

  my $conds = $self->_parse_search($rest);

  unless ($conds) {
    return $event->error_reply("I didn't understand your search.");
  }

  my $uri = URI->new(sprintf("%s/v4/merge_requests/?sort=asc&scope=all&state=opened", $self->api_uri));

  my $page;

  COND: for my $hunk (@$conds) {
    my ($name, $value) = @$hunk;

    if ($name eq 'page') {
      return $event->error_reply("You gave more than one `page:` condition.")
        if defined $page;

      return $event->error_reply("The `page:` condition has to be a positive integer.")
        unless $value =~ /\A[0-9]+\z/ && $value > 0;

      $page = $value;

      next COND;
    }

    if ($name eq 'author' or $name eq 'assignee') {
      $name = "$name\_id";

      if ($value eq '*' or $value eq '~') {
        $value = $value eq '*' ? 'Any' : 'None';
      } else {
        return $event->error_reply("I don't know who $value is.")
          unless my $who = $self->resolve_name($value, $event->from_user);

        return $event->error_reply("I don't know who the GitLab user id for " .  $who->username . ".")
          unless my $user_id = $self->get_user_preference($who, 'user-id');

        $value = $user_id;
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
      return $event->error_reply("The value for `wip:` must be yes, no, or both.")
        unless $value eq 'yes' or $value eq 'no';

      $uri->query_param_append($name, $value);
      next COND;
    }

    return $event->error_reply("Unknown query token: $name");
  }

  $page //= 1;

  $Logger->log("GitLab GET: $uri");

  my $http_future = $self->hub->http_get(
    $uri,
    'PRIVATE-TOKEN' => $self->api_token,
    async => 1,
  );

  $http_future->on_done(sub ($res) {
    unless ($res->is_success) {
      $Logger->log([ "Error: %s", $res->as_string ]);
      return;
    }

    my $data = $JSON->decode($res->decoded_content);

    return $event->error_reply("No results!")
      if ! @$data;

    my $zero = ($page-1) * 10;

    return $event->error_reply("You've gone past the last page!")
      if $zero > $#$data;

    my $pages = ceil(@$data / 10);
    my @page  = grep {; $_ } $data->@[ $zero .. $zero+9 ];

    my $text  = "Results (page $page/$pages):\n";
    my $slack = "Results (page $page/$pages):\n";
    for my $mr (@page) {
      $text  .= "* $mr->{title}\n";
      $slack .= sprintf "<%s|MR> %s [ by %s ]\n",
        $mr->{web_url},
        $mr->{title},
        $mr->{author}{username};
    }

    $event->reply($text, { slack => $slack });
    return;
  })->retain;
}

sub handle_merge_request ($self, $event) {
  $event->mark_handled if $event->was_targeted;

  my @mrs = $event->text =~ /(?:^|\s)([-_a-z]+!\d+)(?=\W|$)/gi;
  state $dt_formatter = DateTimeX::Format::Ago->new(language => 'en');

  state $base = $self->url_base;
  my %found = $event->text =~ m{\Q$base\E/(.*?/.*?)/merge_requests/([0-9]+)};

  for my $key (keys %found) {
    my $num = $found{$key};
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

    my $http_future = $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
      async => 1,
    );
    push @futures, $http_future;

    $http_future->on_done(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);
        return;
      }

      my $data = $JSON->decode($res->decoded_content);

      my $key = $self->_key_for_gitlab_data($event, $data);
      if ($self->has_expanded_mr_recently($key)) {
        $declined_to_reply++;
        return;
      }

      $self->note_mr_expansion($key, time);

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
          value => $dt_formatter->format_datetime($created),
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
            value => $dt_formatter->format_datetime($dt),
            short => \1,
          };
        }
      }

      if ($data->{upvotes} || $data->{downvotes}) {
        push @fields, {
          title => "Review status",
          value => sprintf('%s %s, %s %s',
            $data->{upvotes}, PL_N('upvote', $data->{upvotes}),
            $data->{downvotes}, PL_N('downvote', $data->{downvotes})),
          short => \1
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
  my %found = $event->text =~ m{\Q$base\E/(.*?/.*?)/commit/([0-9a-f]{6,40})}i;

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
      async => 1,
    );
    push @futures, $http_future;

    $http_future->on_done(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);
        return;
      }

      my $data = $JSON->decode($res->decoded_content);

      my $key = $self->_key_for_gitlab_data($event, $data);
      if ($self->has_expanded_commit_recently($key)) {
        $declined_to_reply++;
        return;
      }

      $self->note_commit_expansion($key, time);

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

sub mr_report ($self, $who) {
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
      async => 1,
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

    my $string = q{};

    my $wipstr = sub ($mrs) {
      my $wip = grep {; $_->{title} =~ /^wip:/i } @$mrs;
      return $wip
        ? (sprintf ' (of which %i %s WIP)', $wip, PL_V('is', $wip))
        : '';
    };

    if (@filed) {
      $string .= sprintf "\N{LOWER LEFT CRAYON} Merge %s waiting on others: %i%s\n",
        PL_N('request', 0+@filed), 0+@filed, $wipstr->(\@filed);
    }

    if (@assigned) {
      my $wip = grep {; $_->{title} =~ /^wip:/i } @filed;
      $string .= sprintf "\N{LOWER LEFT CRAYON} Merge %s to review: %i%s\n",
        PL_N('request', 0+@assigned), 0+@assigned, $wipstr->(\@assigned);
    }

    if (@selfies) {
      my $wip = grep {; $_->{title} =~ /^wip:/i } @filed;
      $string .= sprintf "\N{LOWER LEFT CRAYON} Self-assigned merge %s: %i%s\n",
        PL_N('request', 0+@selfies), 0+@selfies, $wipstr->(\@selfies);
    }

    chomp $string;

    return Future->done([ $string, { slack => $string } ]);
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
