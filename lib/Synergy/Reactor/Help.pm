use v5.24.0;
package Synergy::Reactor::Help;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first uniq);

sub listener_specs {
  return {
    name      => 'help',
    method    => 'handle_help',
    exclusive => 1,
    predicate => sub ($self, $e) {
      return unless $e->was_targeted;
      return 1 if $e->text =~ /\A help (?: \s+ (.+) )? \z/ix;
      return;
    },
    help_entries => [
      { title => "help", text => "provides help with using the bot" },
    ],
  };
}

sub handle_help ($self, $event) {
  $event->mark_handled;

  my @help = map {; $_->help_entries }
             map {; $_->listeners }
             $self->hub->reactors;

  my ($help, $rest) = split /\s+/, $event->text, 2;

  unless ($rest) {
    my $help_str = join q{, }, uniq sort map {; $_->{title} } @help;
    $event->reply("Help entries: $help_str");
    return;
  }

  $rest = lc $rest;
  $rest =~ s/\s+\z//;

  @help = grep {; fc $_->{title} eq fc $rest } @help;

  unless (@help) {
    $event->reply("Sorry, I don't have any help on that topic.");
    return;
  }

  $event->reply(join qq{\n}, sort map {; $_->{text} } @help);
  return;
}

1;
