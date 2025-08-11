use v5.36.0;
use utf8;
package Synergy::Reactor::GitHub;

use Moose;
with 'Synergy::Role::Reactor::CommandPost',
     'Synergy::Role::HasPreferences';

use namespace::clean;
use Future::AsyncAwait;
use JSON::MaybeXS;
use Slack::BlockKit::Sugar -all => { -prefix => 'bk_' };
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Util qw(reformat_help);
use Time::Duration qw(ago);
use URI::Escape;

my $JSON = JSON::MaybeXS->new->utf8->canonical;

has github_orgs => (
  isa => 'ArrayRef[Str]',
  traits  => [ 'Array' ],
  handles => { github_orgs => 'elements' },
  required => 1,
);

command 'ghr?' => {
  help => reformat_help(<<~'EOH'),
    See your review requests.
    EOH
} => async sub ($self, $event, $rest) {
  my $data = await $self->_get_prs_for_review($event->from_user);

  my $text = q{};
  my @block_items;

  my $list = q{};

  for my $pr ($data->{prs}->@*) {
    $text .= "* $pr->{title} / $pr->{pull_request}{html_url}\n";

    push @block_items, bk_richsection(bk_link(
      $pr->{pull_request}{html_url},
      $pr->{title},
      { unsafe => 1 }, # Does this suppress preview??
    ));
  }

  return await $event->reply(
    $text,
    {
      slack_postmessage_args => { unfurl_links => \0 },
      slack => bk_blocks(bk_richblock(bk_ulist(@block_items))),
    },
  );
};

my sub _next_and_prev_uris ($http_response) {
  # Dreadful, I apologize. -- rjbs, 2024-11-18
  my $link = $http_response->header('Link');
  return unless $link;

  my ($prev, $next);

  my @items = split /, /, $link;
  for my $item (@items) {
    my ($bracketed, @params) = split /; /, $item;
    my ($uri) = $bracketed =~ /\A<(.+)>\z/;
    my %param = map {; split /=/, $_ } @params;
    my $rel = $param{rel};
    next unless $rel;
    $rel =~ s/"//g;

    $prev = $uri if $rel eq 'prev';
    $next = $uri if $rel eq 'next';
  }

  return ($prev, $next);
}

sub _query ($self) {
  my $org_str = join q{ }, map {; "org:$_" } $self->github_orgs;

  return "type:pr $org_str state:open review-requested:\@me";
}

async sub _get_prs_for_review ($self, $user) {
  my $display_page =  1;
  my $per_page     = 10;

  my $username  = $self->get_user_preference($user, 'username');
  my $api_token = $self->get_user_preference($user, 'api-token');

  Synergy::X->throw_public("I don't know the GitHub username for that user")
    unless $username;

  Synergy::X->throw_public("I don't have a GitHub API token for that user")
    unless $api_token;

  my $url = URI->new("https://api.github.com/search/issues");
  $url->query_form(q => $self->_query);

  my @prs;
  my $saw_last_page;

  PAGE: until (@prs >= $display_page*$per_page) {
    $Logger->log_debug("GitHub GET: $url");

    my $res = await $self->hub->http_get(
      $url,
      'Authorization' => "Bearer $api_token",
    );

    unless ($res->is_success) {
      $Logger->log([ "error fetching pull requests: %s", $res->as_string ]);
      $Logger->log([ "error fetching pull requests: %s", $res->request->as_string ]);
      Synergy::X->throw_public("Something went wrong fetching pull requests.");
    }

    my ($prev, $next) = _next_and_prev_uris($res);

    my $mr_batch = $JSON->decode($res->decoded_content);

    my @items = $mr_batch->{items}->@*;
    unless (@items) {
      last PAGE;
    }

    my $zero = ($display_page-1) * $per_page;

    if ($zero > $#items) {
      Synergy::X->throw_public("You've gone past the last page!");
      return;
    }

    push @prs, @items;
    last unless $next;
    $url = URI->new($next);
  }

  my $zero = ($display_page-1) * $per_page;
  my @page = grep {; $_ } @prs[ $zero .. $zero+$per_page-1 ];

  return {
    page_number => $display_page,
    first_index => $zero + 1,
    last_index  => $zero + @page,
    prs         => \@page,
  };
}

async sub pr_report ($self, $who, $arg = {}) {
  my @futures;

  my $username  = $self->get_user_preference($who, 'username');
  my $api_token = $self->get_user_preference($who, 'api-token');
  return unless $username && $api_token;

  my $data = await $self->_get_prs_for_review($who);

  return unless $data;

  my $query = $self->_query;

  my $url = URI->new("https://github.com/search");
  $url->query_form(q => $self->_query);

  return unless $data->{prs}->@*;

  return [
    "\N{PENCIL}\N{VARIATION SELECTOR-16} Pull requests awaiting review: " . $data->{prs}->@*,
    {
      slack => sprintf "\N{PENCIL}\N{VARIATION SELECTOR-16} Pull requests <%s|awaiting review>: %d",
        $url,
        0+$data->{prs}->@*,
    },
  ];
}

__PACKAGE__->add_preference(
  name      => 'username',
  validator => async sub ($self, $value, @) {
    return $value if $value =~ /\A[\-_A-Za-z0-9]+\z/;
    return (undef, "Your username doesn't look like a GitHub username to me.")
  },
  default   => undef,
);

__PACKAGE__->add_preference(
  name      => 'api-token',
  describer => async sub ($self, $value) { defined $value ? "<redacted>" : '<undef>' },
  validator => async sub ($self, $value, @) {
    return $value if $value =~ /\A[_A-Za-z0-9]+\z/;
    return (undef, "Your API token doesn't look like a GitHub API token to me.")
  },
  default   => undef,
);

1;
