use v5.32.0;
use warnings;
package Synergy::Reactor::Notion;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use utf8;

use Future::AsyncAwait;

use JSON::MaybeXS;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';

my $JSON = JSON::MaybeXS->new->utf8;

has api_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has project_db_id => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has trends_db_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has username_domain => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

sub _project_pages ($self) {
  my $db_id = $self->project_db_id;
  my $token = $self->api_token;

  $self->hub->http_post(
    "https://api.notion.com/v1/databases/$db_id/query",

    'User-Agent'      => 'Synergy/2021.05',
    Authorization     => "Bearer $token",
    'Notion-Version'  => '2021-08-16',
    Content_Type      => 'application/json',
    Content => $JSON->encode({
      filter => {
        and => [
          {
            property => 'Stage',
            select   => { does_not_equal => "Won't do" },
          },
          {
            property => 'Stage',
            select   => { does_not_equal => "Done" },
          },
        ]
      }
    }),
  )->then(sub ($res) {
    my $data  = $JSON->decode($res->decoded_content(charset => undef));
    my @pages = $data->{results}->@*;

    return Future->done(@pages);
  });
}

responder my_projects => {
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($self, $text, @) { fc $text eq 'my projects' ? [] : () },
  help_titles => [ 'my projects', 'projects' ],
  help        => "*my projects*: show all the projects you're working on in Notion",
} => async sub ($self, $event) {
  $event->mark_handled;

  my @pages = await $self->_project_pages;

  my $reply = q{};
  my $slack = q{};

  my $email = $event->from_user->username . '@' . $self->username_domain;

  @pages =
    map  {; $_->[0] }
    sort {; $a->[1] cmp $b->[1] }
    map  {;
      [
        $_,
        join(q{ - }, map {; $_->{plain_text} } $_->{properties}{Name}{title}->@*)
      ]
    } @pages;

  for my $page (@pages) {
    next if $page->{properties}{'On Hold'}{checkbox};

    my $stage = $page->{properties}{Stage}{select}{name};
    next if $stage eq 'Done';
    next if $stage eq q{Won't do};

    my @people = (
      $page->{properties}{'Team (Active)'}{people}->@*,
      $page->{properties}{'Coordinator'}{people}->@*,
    );

    next unless grep {; $_->{person}{email} eq $email } @people;

    my $title = join q{ - },
      map {; $_->{plain_text} } $page->{properties}{Name}{title}->@*;

    my $emoji = $page->{icon}{emoji} // "\N{FILE FOLDER}";

    my $safe_title = $title;
    $safe_title =~ s{[^A-Za-z0-9]}{-}g;

    my $id = $page->{id} =~ s/-//gr;

    my $href = $page->{url};

    my $tag = $page->{properties}{Hashtag}{rich_text}[0]{plain_text} // '';
    $tag = "##$tag" if $tag;

    $reply .= sprintf "%s %s%s (%s)\n",
      $emoji, $title, ($tag ? " $tag" : q{}), $stage;

    $slack .= sprintf "<%s|%s %s>%s (%s)\n",
     $href, $emoji, $title, ($tag ? " *$tag*" : q{}), $stage;
  }

  unless (length $reply) {
    return await $event->reply("Looks like you've got no projects right now!");
  }

  return await $event->reply($reply, { slack => $slack });
};

responder support_trends => {
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($self, $text, @) { $text =~ /\Asupport trends/i ? [] : () },
  help_titles => [ 'support trends' ],
  help        => 'Show all the Issues & Trends support is tracking in Notion; '
               . 'you can add /future to show things resolved in the future.',
} => async sub ($self, $event) {
  $event->mark_handled;

  my $want_future = $event->text =~ m{/future}i;

  my $db_id = $self->trends_db_id;
  my $token = $self->api_token;
  my $now = DateTime->now(time_zone => 'Etc/UTC')->iso8601;

  my $res = await $self->hub->http_post(
    "https://api.notion.com/v1/databases/$db_id/query",

    'User-Agent'      => 'Synergy/2021.05',
    Authorization     => "Bearer $token",
    'Notion-Version'  => '2021-08-16',
    Content_Type      => 'application/json',
    Content => $JSON->encode({
      filter => {
        or => [
          {
            property => "Resolved",
            date => { is_empty => \1 },
          },
          {
            property => "Resolved",
            date => { after => $now },
          },
        ]
      }
    }),
  );

  my $data  = $JSON->decode($res->decoded_content(charset => undef));

  my @pages =
    map  {; $_->[0] }
    sort {; $a->[1] cmp $b->[1] || $a->[2] cmp $b->[2] }
    map  {;
      [
        $_,
        $_->{properties}{Began}{date}{start} // '',
        $_->{properties}{created_time},   # just for sort stability
      ]
    } $data->{results}->@*;

  my $reply = q{};
  my $slack = q{};

  for my $page (@pages) {
    my $title = join q{ - },
      map {; $_->{plain_text} } $page->{properties}{Name}{title}->@*;

    my $emoji = $page->{icon}{emoji} // "\N{WARNING SIGN}";

    my $start = $page->{properties}{Began}{date}{start};
    my $end = $page->{properties}{Resolved}{date}{start};

    next if $end && ! $want_future;

    my $since = $end
              ? sprintf("%s – %s", $start, $end)
              : sprintf("since %s", $start);

    my $safe_title = $title;
    $safe_title =~ s{[^A-Za-z0-9]}{-}g;

    my $id = $page->{id} =~ s/-//gr;

    my $href = "https://www.notion.so/$safe_title-$id";

    $reply .= "$emoji $title ($since)\n";
    $slack .= sprintf "<%s|%s %s> (%s)\n", $href, $emoji, $title, $since;
  }

  unless (length $reply) {
    return await $event->reply("Looks like everything has been under control!");
  }

  return await $event->reply($reply, { slack => $slack });
};

1;
