use v5.36.0;
package Synergy::Reactor::Help;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;
use Future::AsyncAwait;
use Synergy::CommandPost;
use List::Util qw(first uniq);
use Try::Tiny;

command help => {
  aliases => [ 'halp' ],
  help    => <<'END'
*help*: list all the topics with help
*help* `TOPIC`: provide help on a topic
END
} => async sub ($self, $event, $rest) {
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

    return await $event->error_reply(join q{  },
      qq{You can say "help TOPIC" for help on a topic.},
      qq{Here are topics I know about: $help_str}
    );
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
      return await $event->error_reply("Sorry, I don't know that preference.");
    }

    my $text = $help->{help} // $help->{description} // "(no help)";
    return await $event->reply("*$pref_str* - $text");
  }

  @help = grep {; fc $_->{title} eq fc $rest } @help;

  unless (@help) {
    return await $event->error_reply("Sorry, I don't have any help on that topic.");
  }

  return await $event->reply(join qq{\n}, sort map {; $_->{text} } @help);
};

1;
