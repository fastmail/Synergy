use v5.36.0;
package Synergy::Reactor::Report;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::Logger '$Logger';

use Slack::BlockKit::Sugar -all => { -prefix => 'bk_' };

has default_report => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_default_report',
);

has reports => (
  isa => 'HashRef',
  traits    => [ 'Hash' ],
  required  => 1,
  handles   => {
    report_names => 'keys',
    report_named => 'get',
    _create_report_named => 'set',
  },
);

after register_with_hub => sub ($self, @) {
  Carp::confess("the report name 'list' is reserved")
    if $self->report_named('list');

  $self->_create_report_named(list => {
    title     => "Available Reports",
    sections  => [
      [ $self->name, 'report_report' ],
    ]
  });
};

async sub fixed_text_report ($self, $who, $arg = {}) {
  return [ $arg->{text}, $arg->{alts} ];
}

async sub begin_report ($self, $report, $target) {
  my $hub = $self->hub;

  my @results;

  for my $section ($report->{sections}->@*) {
    my ($reactor_name, $method, $arg) = @$section;

    my $duty = $arg->{only_on_duty};
    next if $duty && ! $target->is_on_duty($self->hub, $duty);

    if ($arg->{only_oncall}) {
      # TODO: break "pagerduty" out so it's (a) optional and (b) a property,
      # not a fixed string -- rjbs, 2025-02-05
      my @usernames = map {; $self->username_from_pd($_) }
                      $hub->reactor_named('pagerduty')->oncall_list;

      next unless grep {; $_ eq $target->username } @usernames;
    }

    my $reactor = $hub->reactor_named($reactor_name);

    # I think this will need rejiggering later. -- rjbs, 2019-03-22
    push @results, $reactor->$method(
      $target,
      ($arg ? $arg : ()),
    );
  }

  await Future->wait_all(@results);

  my @hunks = map {;
    if ($_->is_failed) {
      $Logger->log([ "Failure during report: %s", [ $_->failure ] ]);
    }

    $_->is_done ? $_->get
                : [ "[ internal error during report ]" ]
  } @results;

  return unless @hunks;

  my $title = $report->{title};
  my $text  = qq{$title for } . $target->username . q{:};

  my @slack_blocks = bk_richblock(bk_richsection(bk_bold($text)));

  while (my $hunk = shift @hunks) {
    $text .= "\n" . $hunk->[0];

    if (my $slack = $hunk->[1]{slack}) {
      push @slack_blocks, ref $slack ? $slack->blocks : bk_mrkdwn($slack);
    } else {
      push @slack_blocks, bk_text($hunk->[0]);
    }
  }

  return ($text, { slack => bk_blocks(@slack_blocks) });
}

command report => {
  help => q{report [which] [for USER]: show reports for a user; "report list" for a list of reports},
} => async sub ($self, $event, $rest) {
  my $report_name;
  my $who_name;

  if (
    length $rest
    &&
    $rest =~ /\A
      (     (?<which>[a-z]+) )?
      ( \s+ for \s+ (?<who> [a-z]+ ) )?
      \s*
    \z/nix
  ) {
    $who_name = $+{who};
    $report_name = $+{which};
  }

  if (not defined $report_name) {
    if ($self->has_default_report) {
      $report_name = $self->default_report;
    } else {
      my $names = join q{, }, $self->report_names;
      return $event->error_reply("Which report?  I know these: $names.");
    }
  }

  $who_name //= $event->from_user->username;

  $report_name = fc $report_name;

  my $target = $self->resolve_name($who_name, $event->from_user);

  my $report = $self->report_named($report_name);
  unless ($report) {
    my $names = join q{, }, $self->report_names;
    return await $event->error_reply("Sorry, I don't know that report!  I know these reports: $names.");
  }

  unless ($target) {
    return await $event->error_reply("Sorry, I don't know who $who_name is!");
  }

  $event->reply(
    "I'm generating that report now, it'll be just a moment",
    {
      slack_reaction => {
        event => $event,
        reaction => 'hourglass_flowing_sand',
      }
    },
  );

  # This \u is bogus, we should allow canonical name to be in the report
  # definition. -- rjbs, 2019-03-22
  my %local_report = (
    %$report,
    title => $report->{title} // "\u$report_name report",
  );

  my ($text, $alt) = await $self->begin_report(\%local_report, $target);

  unless (defined $text) {
    $event->private_reply(
      "Nothing to report.",
      {
        slack_reaction => {
          event => $event,
          reaction => '-hourglass_flowing_sand',
        }
      },
    );

    return await $event->reply("I have nothing at all to report!");
  }

  $event->private_reply(
    "Report sent!",
    {
      slack_reaction => {
        event => $event,
        reaction => '-hourglass_flowing_sand',
      }
    },
  );

  return await $event->reply($text, {
    %$alt,
    slack_postmessage_args => { unfurl_links => \0 },
  });
};

async sub report_report ($self, $who, $arg = {}) {
  my $text  = q{};
  my $slack = q{};

  for my $name (sort $self->report_names) {
    my $report = $self->report_named($name);
    $text   .= "$name: "   . ($report->{description} // "the $name report") . "\n";
    $slack  .= "*$name*: " . ($report->{description} // "the $name report") . "\n";
  }

  return [ $text, { slack => $slack } ];
}

1;
