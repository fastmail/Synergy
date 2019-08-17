use v5.24.0;
use warnings;
package Synergy::Reactor::Report;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => "report",
    method    => "report",
    exclusive => 1,
    predicate => sub ($, $e) {
      return unless $e->was_targeted;
      return unless $e->text =~ /^\s*report(\s+[a-z]+)?(\s+for\s+([a-z]+))?\s*$/i;
      return 1;
    },
    help_entries => [
      {
        title => "report",
        text => q{report [which] [for USER]: show reports for a user; "report list" for a list of reports},
      }
    ],
  };
}

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

sub report ($self, $event) {
  my $report_name;
  my $who_name;

  if (
    $event->text =~ /\A
      \s*
      report
      ( \s+ (?<which>[a-z]+) )?
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

  $event->mark_handled;

  my $report = $self->report_named($report_name);
  unless ($report) {
    my $names = join q{, }, $self->report_names;
    return $event->error_reply("Sorry, I don't know that report!  I know these reports: $names.");
  }

  unless ($target) {
    return $event->error_reply("Sorry, I don't know who $who_name is!");
  }

  my $hub = $self->hub;

  $event->reply(
    "I'm generating that report now, it'll be just a moment",
    {
      slack_reaction => {
        event => $event,
        reaction => 'hourglass_flowing_sand',
      }
    },
  );

  my @results;

  for my $section ($report->{sections}->@*) {
    my ($reactor_name, $method, $arg) = @$section;

    my $reactor = $hub->reactor_named($reactor_name);

    # I think this will need rejiggering later. -- rjbs, 2019-03-22
    push @results, $reactor->$method(
      $target,
      ($arg ? $arg : ()),
    );
  }

  # unwrap collapses futures, but only if given exactly one future, so we map
  # -- rjbs, 2019-03-21
  my @hunks = map {; Future->unwrap($_) } @results;

  unless (@hunks) {
    $event->private_reply(
      "Nothing to report.",
      {
        slack_reaction => {
          event => $event,
          reaction => '-hourglass_flowing_sand',
        }
      },
    );

    return $event->reply("I have nothing at all to report!");
  }

  # This \u is bogus, we should allow canonical name to be in the report
  # definition. -- rjbs, 2019-03-22
  my $title = $report->{title} // "\u$report_name report";
  my $text  = qq{$title for } . $target->username . q{:};
  my $slack = qq{*$text*};

  while (my $hunk = shift @hunks) {
    $text   .= "\n" . $hunk->[0];
    $slack  .= "\n" . ($hunk->[1]{slack} // qq{`$hunk->[0]`});
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

  return $event->reply(
    $text,
    {
      slack => $slack,
    },
  );
}

sub report_report ($self, $who, $arg = {}) {
  my $text  = q{};
  my $slack = q{};

  for my $name (sort $self->report_names) {
    my $report = $self->report_named($name);
    $text   .= "$name: "   . ($report->{description} // "the $name report") . "\n";
    $slack  .= "*$name*: " . ($report->{description} // "the $name report") . "\n";
  }

  return Future->done([ $text, { slack => $slack } ]);
}

1;
