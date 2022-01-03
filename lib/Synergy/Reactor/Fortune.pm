use v5.24.0;
use warnings;
package Synergy::Reactor::Fortune;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use JSON::MaybeXS ();
use Path::Tiny qw(path);
use utf8;

my $JSON = JSON::MaybeXS->new->utf8->pretty;

# json array
has fortune_path => (
  is => 'ro',
  required => 1,
);

has _fortunes => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  lazy => 1,
  default => sub ($self) {
    my $p = path($self->fortune_path);
    return [] unless $p->is_file;
    return $JSON->decode($p->slurp);
  },
  handles => {
    all_fortunes  => 'elements',
    fortune_count => 'count',
    get_fortune   => 'get',
    add_fortune   => 'push',
  },
);

# source-ident => [ count, most-recent-epoch ]
has _scolding_counts => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  default => sub { {} },
  handles => {
    remove_scolding    => 'delete',
    recent_scoldings   => 'keys',
    scolding_data_for  => 'get',
    note_scolding_data => 'set',
  },
);

# If it's been more than 5 minutes since the last time you asked for a fortune
# in this channel, you can ask again.
has scold_reaper => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return IO::Async::Timer::Periodic->new(
      interval => 30,
      on_tick  => sub {
        my $then = time - (60 * 5);

        for my $key ($self->recent_scoldings) {
          my ($count, $ts) = $self->scolding_data_for($key)->@*;
          $self->remove_scolding($key) if $ts lt $then;
        }
      },
    );
  }
);

sub listener_specs {
  return (
    {
      name      => 'provide fortune',
      method    => 'handle_fortune',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /\Afortune\s*\z/i; },
      help_entries => [
        { title => 'fortune', text => <<'END', },
• *fortune*: get a random statement of wisdom, wit, or whatever
• *add fortune: `TEXT`*: add a new fortune to the database
END
      ],
    },
    {
      name => 'add fortune',
      method => 'handle_add_fortune',
      exclusive => 1,
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /\Aadd\s+fortune:/i; },
    },
  );
}

sub start ($self) {
  $self->hub->loop->add($self->scold_reaper->start);
}

sub handle_fortune ($self, $event) {
  $event->mark_handled;

  if ($self->fortune_count == 0) {
    return $event->reply("I don't have any fortunes yet!");
  }

  # no spamming public channels with fortunes, yo.
  if ($event->is_public) {
    my $src = $event->source_identifier;

    my $data = $self->scolding_data_for($src) // [];
    my $count = $data->[0] // 0;

    $self->note_scolding_data($src, [ $count + 1, time]);

    if ($count >= 3) {
      $event->ephemeral_reply("No fishing for your favorite fortunes in public!");

      $event->reply(
        "No fishing for your favorite fortunes in public!",
        {
          slack_reaction => {
            event => $event,
            reaction => 'no_entry_sign',
          }
        },
      );

      return;
    }
  }

  my $i = int(rand($self->fortune_count));
  my $fortune = $self->get_fortune($i);
  return $event->reply($fortune);
}

sub handle_add_fortune ($self, $event) {
  $event->mark_handled;

  my ($f) = $event->text =~ /\Aadd\s+fortune:\s+(.*)/ism;
  return $event->error_reply("I didn't find a fortune there!") unless $f;

  # TODO: add attribution data, maybe
  $self->add_fortune($f);
  $self->_save_fortunes;

  return $event->reply("Fortune added!");
}

sub _save_fortunes ($self) {
  my $p = path($self->fortune_path);
  my $data = $JSON->encode($self->_fortunes);
  $p->spew($data);
  return;
}

1;
