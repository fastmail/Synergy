use v5.24.0;
use warnings;
package Synergy::Role::DeduplicatesExpandos;

use MooseX::Role::Parameterized;

use Scalar::Util qw(blessed);
use Synergy::Logger '$Logger';
use Try::Tiny;
use utf8;

use experimental qw(signatures);
use namespace::clean;

parameter expandos => (
  isa => 'ArrayRef[Str]',
  required => 1,
);

role {
  my $p = shift;

  for my $thing ($p->expandos->@*) {
    my $attr_name = "_${thing}_expansion_cache";
    my $guts_name = $attr_name . '_guts';
    my $key_generator = "_expansion_key_for_${thing}";

    # key => time
    has $guts_name => (
      is => 'ro',
      isa => 'HashRef',
      traits => ['Hash'],
      lazy => 1,
      default => sub { {} },
    );

    method $attr_name => sub ($self) {
      my $guts = $self->$guts_name;

      for my $key (keys %$guts) {
        delete $guts->{$key} if time - 300 > $guts->{$key};
      }

      return $guts;
    };

    method $key_generator => sub ($self, $event, $id) {
      # Not using $event->source_identifier here because we don't care _who_
      # triggered the expansion. -- michael, 2019-02-05
      return join(';',
        $id,
        $event->from_channel->name,
        $event->conversation_address
      );
    };

    method "note_${thing}_expansion" => sub ($self, $event, $id) {
      my $key = $self->$key_generator($event, $id);
      $self->$attr_name->{$key} = time;
    };

    method "has_expanded_${thing}_recently" => sub ($self, $event, $id) {
      my $key = $self->$key_generator($event, $id);
      return exists $self->$attr_name->{$key};
    };
  }
};

1;
