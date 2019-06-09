use v5.24.0;
use warnings;
package Synergy::Reactor::DamageReport;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => "report",
    method    => "report",
    exclusive => 1,
    predicate => sub ($, $e) {
      return unless $e->was_targeted;
      return unless $e->text =~ /^\s*([a-z]+\s+)?report(\s+for\s+([a-z]+))?\s*$/i;
      return if ($1//'') eq 'help'; # "help report" should be help on report cmd!
      return 1;
    },
    help_entries => [
      {
        title => "report",
        text => "report [for USER]: show the user's current workload",
      }
    ],
  };
}

has default_report => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has reports => (
  isa => 'HashRef',
  traits    => [ 'Hash' ],
  required  => 1,
  handles   => {
    report_names => 'keys',
    report_named => 'get',
  },
);

sub report ($self, $event) {
  my $report_name;
  my $who_name;

  if (
    $event->text =~ /\A
      \s*
      ((?<which>[a-z]+) \s+ )?
      report
      ( \s+ for \s+ (?<who> [a-z]+ ) )?
      \s*
    \z/nix
  ) {
    $who_name = $+{who};
    $report_name = $+{which};
  }

  $report_name //= $self->default_report;
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

1;
