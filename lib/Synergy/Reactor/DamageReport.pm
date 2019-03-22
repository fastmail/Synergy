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
    name      => "damage-report",
    method    => "damage_report",
    predicate => sub ($, $e) {
      $e->was_targeted &&
      $e->text =~ /^\s*(damage\s+)?report(\s+for\s+([a-z]+))?\s*$/in;
    },
    help_entries => [
      {
        title => "report",
        text => "report [for USER]: show the user's current workload",
      }
    ],
  };
}

has sections => (
  isa => 'ArrayRef',
  traits  => [ 'Array' ],
  default => sub {  []  },
  handles => { sections => 'elements' },
);

sub damage_report ($self, $event) {
  my $who_name;

  if (
    $event->text =~ /\A
      \s*
      ( damage \s+ )?
      report
      ( \s+ for \s+ (?<who> [a-z]+ ) )?
      \s*
    \z/nix
  ) {
    $who_name = $+{who};
  }

  $who_name //= $event->from_user->username;

  my $target = $self->resolve_name($who_name, $event->from_user);

  $event->mark_handled;

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

  for my $section ($self->sections) {
    my ($reactor_name, $method) = @$section;

    my $reactor = $hub->reactor_named($reactor_name);

    push @results, $reactor->$method($target);
  }

  # unwrap collapses futures, but only if given exactly one future, so we map
  # -- rjbs, 2019-03-21
  my @hunks = map {; Future->unwrap($_) } @results;

  unless (@hunks) {
    return $event->reply("I have nothing at all to report.  Woah!");
  }

  my $text  = q{Damage report for } . $target->username . q{:};
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
