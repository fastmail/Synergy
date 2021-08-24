use v5.24.0;
use warnings;
package Synergy::Reactor::Notion;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures lexical_subs);
use namespace::clean;

use utf8;

sub listener_specs {
  return (
    {
      name      => 'my_projects',
      method    => 'handle_my_projects',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless fc $e->text eq 'my projects';
      },
    },
  );
}

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

has username_domain => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

sub handle_my_projects ($self, $event) {
  $event->mark_handled;

  my $db_id = $self->project_db_id;
  my $token = $self->api_token;

  my $res = $self->hub->http_post(
    "https://api.notion.com/v1/databases/$db_id/query",

    'User-Agent'      => 'Synergy/2021.05',
    Authorization     => "Bearer $token",
    'Notion-Version'  => '2021-08-16',
    'Content-Type'    => 'application/json',
    Content => "{}", # TODO: filter here for real
  )->get; # TODO: use sequencing

  my $data  = JSON::MaybeXS->new->utf8->decode( $res->decoded_content(charset => undef) );
  my @pages = $data->{results}->@*;

  my $reply = q{};
  my $slack = q{};

  my $email = $event->from_user->username . '@' . $self->username_domain;

  for my $page (@pages) {
    next if $page->{properties}{'On Hold'}{checkbox};

    my $stage = $page->{properties}{Stage}{select}{name};
    next if $stage eq 'Done';

    my @people = (
      $page->{properties}{'Team (Active)'}{people}->@*,
      $page->{properties}{'Coordinator'}{people}->@*,
    );

    next unless grep {; $_->{person}{email} eq $email } @people;
    my $title = join q{ - }, map {; $_->{plain_text} } $page->{properties}{Name}{title}->@*;

    my $emoji = $page->{icon}{emoji} // "\N{FILE FOLDER}";

    my $safe_title = $title;
    $safe_title =~ s{[^A-Za-z0-9]}{-}g;

    my $id = $page->{id} =~ s/-//gr;

    my $href = "https://www.notion.so/$safe_title-$id";

    $reply .= "$emoji $title ($stage)\n";
    $slack .= sprintf "<%s|%s %s> (%s)\n", $href, $emoji, $title, $stage;
  }

  unless (length $reply) {
    return $event->reply("Looks like you've got no projects right now!");
  }

  $event->reply($reply, { slack => $slack });
}

1;
