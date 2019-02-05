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
use JSON 2 ();
use List::Util qw(uniq);
use MIME::Base64;
use YAML::XS;
use Synergy::Logger '$Logger';
use URI::Escape;
use Future 0.36;  # for ->retain

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
      name => 'mention-mr',
      method => 'handle_merge_request',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /(^|\s)[-_a-z]+!\d+(\W|$)/in;

        my $base = $self->reactor->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?merge_requests/;
      }
    },
    {
      name => 'mr-report',
      method => 'handle_mr_report',
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /^\s*mr report\s*\z/i;
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

      my $slack = {
        text        => "",
        attachments => $JSON->encode([{
          fallback    => "$mr: $data->{title} [$data->{state}] $data->{web_url}",
          author_name => $data->{author}->{name},
          author_icon => $data->{author}->{avatar_url},
          title       => "$mr: $data->{title}",
          title_link  => "$data->{web_url}",
          color       => $color,
          fields      => \@fields,
        }]),
      };

      $event->reply($reply, { slack => $slack });
      $replied++;
    });
  }

  Future->wait_all(@futures)->on_done(sub {
    return if $replied || ! $event->was_targeted;
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
        attachments => $JSON->encode([{
          fallback    => "$data->{author_name}: $data->{short_id} $data->{title} $commit_url",
          text        => $msg,
        }]),
      };

      $event->reply($reply, { slack => $slack });
      $replied++;
    });
  }

  Future->wait_all(@futures)->on_done(sub {
    return if $replied || ! $event->was_targeted;
    $event->reply("I couldn't find a commit with that description.");
  })->retain;
}

sub handle_mr_report ($self, $event) {
  $event->mark_handled;

  my $user_id = $self->get_user_preference($event->from_user, 'user-id');

  unless (defined $user_id) {
    return $event->reply("I can't check your MR status, you don't have an user-id preference set!");
  }

  my %result;
  my @futures;

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
    push @futures, $http_future;

    $http_future->on_done(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);
        return $event->reply(
          "Something when wrong when trying to get your $type merge requests.",
        );
      }

      my $data = $JSON->decode($res->decoded_content);
      for my $mr (@$data) {
        $mr->{_isBacklogged} = 1
          if grep {; lc $_ eq 'backlogged' } $mr->{labels}->@*;

        $mr->{_isSelfAssigned} = 1
          if $mr->{assignee} && $mr->{assignee}{id} == $user_id;
      }
      $result{$type} = $data;
    });
  }

  Future->wait_all(@futures)->on_done(sub {
    my $template = <<'EOT';
Open merge requests you filed: %s (%s backlogged)
Open merge request assigned to you: %s (%s backlogged)
Open merge requests in both groups: %s (%s backlogged)
EOT

    $event->reply(sprintf
      $template,
      0 + $result{filed}->@*,
      0 + (grep { $_->{_isBacklogged} } $result{filed}->@*),
      0 + $result{assigned}->@*,
      0 + (grep { $_->{_isBacklogged} } $result{assigned}->@*),
      0 + (grep { $_->{_isSelfAssigned} } $result{filed}->@*),
      0 + (grep { $_->{_isSelfAssigned} && $_->{_isBacklogged} }
            $result{filed}->@*),
    );
  })->retain;
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  validator => sub ($value) {
    return $value if $value =~ /\A[0-9]+\z/;
    return (undef, "Your user-id must be a positive integer.")
  },
  default   => undef,
);

1;
