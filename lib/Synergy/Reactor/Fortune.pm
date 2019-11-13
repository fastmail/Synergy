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

sub listener_specs {
  return (
    {
      name      => 'provide fortune',
      method    => 'handle_fortune',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return 1 if $e->text =~ /\Afortune\s*\z/i;
        return;
      },
    },
    {
      name => 'add fortune',
      method => 'handle_add_fortune',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return 1 if $e->text =~ /\Aadd\s+fortune:/i;
        return;
      },
    },
  );
}

sub handle_fortune ($self, $event) {
  $event->mark_handled;

  if ($self->fortune_count == 0) {
    return $event->reply("I don't have any fortunes yet!");
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
