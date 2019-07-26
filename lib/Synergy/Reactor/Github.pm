use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::Github;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;
use DateTime::Format::ISO8601;
use DateTimeX::Format::Ago;
use Digest::MD5 qw(md5_hex);
use Future 0.36;  # for ->retain
use JSON::MaybeXS;
use Lingua::EN::Inflect qw(PL_N PL_V);
use List::Util qw(uniq);
use MIME::Base64;
use POSIX qw(ceil);
use Synergy::Logger '$Logger';
use URI::Escape;
use YAML::XS;

my $JSON = JSON::MaybeXS->new->utf8->canonical;

# TODO factor this out

has api_token => (
  is => 'ro',
  isa => 'Str',
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
  default => sub { $_[0]->api_uri =~ s|/api\.|/|r; },
);

# each has user_name, repo_name, shortcut
has _repositories => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  traits => ['Array'],
  required => 1,
  init_arg => 'repositories',
  handles => {
    repositories => 'elements',
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
  },
  lazy => 1,
  default => sub ($self) {
    my %shortcuts;

    for my $repo ($self->repositories) {
      my $key = $repo->{user_name} . q{/} . $repo->{repo_name};
      $shortcuts{ $repo->{shortcut} } = lc $key;
    }

    return \%shortcuts;
  },
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

sub start ($self) {
  $self->hub->loop->add($self->expansion_record_reaper->start);
}

sub listener_specs {
  return (
    {
      name => 'mention-gh-commit',
      method => 'handle_commit',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /(^|\s)[-_a-z]+\@[0-9a-f]{7,40}(\W|$)/in;

        state $base = $self->reactor->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?commit/;
      }
    },
  );
}

sub _key_for_github_data ($self, $event, $data) {
  # Not using $event->source_identifier here because we don't care _who_
  # triggered the expansion. -- michael, 2019-02-05
  return join(';',
    $data->{url},
    $event->from_channel->name,
    $event->conversation_address
  );
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

    my $url = sprintf("%s/repos/%s/commits/%s",
      $self->api_uri,
      $project_id,
      $sha,
    );

    my $http_future = $self->hub->http_get(
      $url,
      # XXX authentication
      async => 1,
    );
    push @futures, $http_future;

    $http_future->on_done(sub ($res) {
      unless ($res->is_success) {
        $Logger->log([ "Error: %s", $res->as_string ]);
        return;
      }

      my $data = $JSON->decode($res->decoded_content);

      my $key = $self->_key_for_github_data($event, $data);
      if ($self->has_expanded_commit_recently($key)) {
        $declined_to_reply++;
        return;
      }

      $self->note_commit_expansion($key, time);

      my $author_name = $data->{commit}{author}{name};
      my $author_date = $data->{commit}{author}{date};
      my $commit_msg  = $data->{commit}{message};
      my ($short_msg) = $commit_msg =~ /^(.+)\n/;
      my $short_sha   = substr $data->{sha}, 0, 8;

      my $commit_url = sprintf("%s/%s/commit/%s",
        $self->url_base,
        $project_id,
        $short_sha,
      );

      my $reply = "$commit [$author_name]: $short_msg ($commit_url)";
      my $slack = sprintf("<%s|%s>: %s [%s]",
        $commit_url,
        $commit,
        $short_msg,
        $author_name,
      );

      my $author_icon = sprintf("https://www.gravatar.com/avatar/%s?s=16",
        md5_hex($data->{commit}{author}{email}),
      );

      my $msg = sprintf("commit <%s|%s>\nAuthor: %s\nDate: %s\n\n%s",
        $commit_url,
        $data->{sha},
        $author_name,,
        $author_date,
        $commit_msg,
      );

      $slack = {
        text        => '',
        attachments => [{
          fallback    => "$author_name: $short_sha $short_msg $commit_url",
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

1;
