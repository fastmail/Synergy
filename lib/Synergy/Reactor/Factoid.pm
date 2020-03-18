use v5.24.0;
use warnings;
package Synergy::Reactor::Factoid;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return (
    {
      name      => 'learn',
      method    => 'handle_learn',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ /\Alearn\s+([^,:]+): (.+)\z/;
      },
      exclusive => 1,
      help_entries => [
        { title => 'learn',
          text  => '*learn `WHAT`: `TEXT`*: learn a new factoid; see also lookup, forget',
        }
      ],
    },
    {
      name      => 'lookup',
      method    => 'handle_lookup',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ /\Alookup\s+\S/;
      },
      exclusive => 1,
      help_entries => [
        { title => 'lookup',
          text  => '*lookup `WHAT`*: look up a factoid in the knowledge base; see also learn, forget',
        }
      ],
    },
    {
      name      => 'forget',
      method    => 'handle_forget',
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return $e->text =~ /\Aforget\s+\S/;
      },
      exclusive => 1,
      help_entries => [
        { title => 'forget',
          text  => '*forget `WHAT`*: delete a factoid from the knowledge base; see also learn, lookup',
        }
      ],
    },
  );
}

sub get_facts ($self) {
  return {} unless my $state = $self->fetch_state;
  $state->{facts} //= {};
}

sub handle_learn ($self, $event) {
  $event->text =~ /\Alearn ([^,:]+): (.+)\z/;

  $event->mark_handled;

  my ($name, $text) = ($1, $2);

  my $facts = $self->get_facts;

  if ($facts->{ fc $name }) {
    return $event->reply(qq{I already have a fact for "$name", sorry.});
  }

  $facts->{fc $name} = {
    name => $name,
    text => $text,
    stored_at => time,
    stored_by => ($event->from_user && $event->from_user->username),
  };

  $self->save_state({ facts => $facts });

  return $event->reply(qq{Okay, I've stored that.});
}

sub handle_lookup ($self, $event) {
  $event->text =~ /\Alookup\s+(.+)/;
  my $name = $1;

  $event->mark_handled;

  my $facts = $self->get_facts;

  if (my $entry = $facts->{ fc $name }) {
    return $event->reply(qq{Here's what I have under "$entry->{name}": $entry->{text}});
  }

  return $event->reply("Sorry, I didn't find anything under that name.");
}

sub handle_forget ($self, $event) {
  $event->text =~ /\Aforget\s+(.+)/;

  $event->mark_handled;

  my $name = $1;

  my $facts = $self->get_facts;

  unless ($facts->{ fc $name }) {
    return $event->reply(qq{I don't have any factoids stored under "$name"!});
  }

  delete $facts->{ fc $name };

  $self->save_state({ facts => $facts });

  return $event->reply(qq{Okay, I've forgotten that.});
}

1;
