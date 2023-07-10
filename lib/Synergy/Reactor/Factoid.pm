use v5.32.0;
use warnings;
package Synergy::Reactor::Factoid;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

sub get_facts ($self) {
  return {} unless my $state = $self->fetch_state;
  $state->{facts} //= {};
}

command learn => {
  help => '*learn `WHAT`: `TEXT`*: learn a new factoid; see also lookup, forget',
} => async sub ($self, $event, $rest) {
  my ($name, $text) = $event->text =~ /\Alearn ([^,:]+): (.+)\z/;

  my $facts = $self->get_facts;

  if ($facts->{ fc $name }) {
    return await $event->reply(qq{I already have a fact for "$name", sorry.});
  }

  $facts->{fc $name} = {
    name => $name,
    text => $text,
    stored_at => time,
    stored_by => ($event->from_user && $event->from_user->username),
  };

  $self->save_state({ facts => $facts });

  return await $event->reply(qq{Okay, I've stored that.});
};

command lookup => {
  help => '*lookup `WHAT`*: look up a factoid in the knowledge base; see also learn, forget',
} => async sub ($self, $event, $what) {
  my $facts = $self->get_facts;

  if (my $entry = $facts->{ fc $what }) {
    return await $event->reply(qq{Here's what I have under "$entry->{name}": $entry->{text}});
  }

  return await $event->reply("Sorry, I didn't find anything under that name.");
};

command forget => {
  help => '*forget `WHAT`*: delete a factoid from the knowledge base; see also learn, lookup',
} => async sub ($self, $event, $what) {
  my $facts = $self->get_facts;

  unless ($facts->{ fc $what }) {
    return await $event->reply(qq{I don't have any factoids stored under "$what"!});
  }

  delete $facts->{ fc $what };

  $self->save_state({ facts => $facts });

  return await $event->reply(qq{Okay, I've forgotten that.});
};

1;
