use v5.34.0;
use warnings;
package Synergy::Reactor::Help;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first uniq);
use Try::Tiny;

sub listener_specs {
  return {
    name      => 'help',
    method    => 'handle_help',
    exclusive => 1,
    targeted  => 1,
    predicate => sub ($, $e) { $e->text =~ /\A h[ae]lp (?: \s+ (.+) )? \z/ix },
    help_entries => [
      { title => "help", text => "help: list all the topics with help" },
      { title => "help", text => "help TOPIC: provide help on " },
    ],
  };
}

sub handle_help ($self, $event) {
  $event->mark_handled;

  my ($help, $rest) = split /\s+/, $event->text, 2;

  # Another option here would be to add "requires 'help_entries'" to the
  # Reactor role, but this gets to be a bit of a pain with CommandPost, because
  # it's not a role and so its imported function isn't respected as a method.
  # This could (and probably should) be fixed by making CommandPost a role, but
  # it's a little complicated, so I'm just doing this, because this is easy to
  # do and easy to understand. -- rjbs, 2022-01-02
  my @help = map {; $_->can('help_entries') && $_->help_entries->@* }
             $self->hub->reactors;

  unless ($rest) {
    my $help_str = join q{, }, uniq sort map  {; $_->{title} }
                                         grep {; ! $_->{unlisted} } @help;

    $event->error_reply(qq{You can say "help TOPIC" for help on a topic.  }
                . qq{Here are topics I know about: $help_str});
    return;
  }

  $rest = lc $rest;
  $rest =~ s/\s+\z//;

  if ($rest =~ /\Apreference\s+(\S+)\z/) {
    my $pref_str = $1;

    my ($comp_name, $pref_name) = $pref_str =~ m{
      \A
      ([-_a-z0-9]+) \. ([-_a-z0-9]+)
      \z
    }x;

    my $component = eval { $self->hub->component_named($comp_name) };

    my $help = $component
            && $component->can('preference_help')
            && $component->preference_help->{ $pref_name };

    unless ($help) {
      $event->error_reply("Sorry, I don't know that preference.");
      return;
    }

    my $text = $help->{help} // $help->{description} // "(no help)";
    $event->reply("*$pref_str* - $text");
    return;
  }

  @help = grep {; fc $_->{title} eq fc $rest } @help;

  unless (@help) {
    $event->error_reply("Sorry, I don't have any help on that topic.");
    return;
  }

  $event->reply(join qq{\n}, sort map {; $_->{text} } @help);
  return;
}

1;
