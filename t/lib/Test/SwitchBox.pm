use v5.32.0;
use warnings;

package Test::SwitchBox;
use Moose;
extends 'Synergy::SwitchBox';

use experimental qw(isa signatures);

use String::Switches ();
use Test::Deep ':v1';
use Test::More;

sub switches_ok ($self, $str, $want, $desc) {
  my ($switches, $error) = String::Switches::parse_switches($str);

  confess("input string did not parse") unless $switches;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $set;

  subtest "switches_ok: $desc" => sub {
    $set = eval {
      $self->handle_switches($switches);
    };

    if ($@ and $@ isa 'Synergy::SwitchBox::Error') {
      my $error = $@;
      fail("SwitchBox rejected the input");
      diag(explain([ $error->as_structs ]));
      return;
    }

    isa_ok($set, 'Synergy::SwitchBox::Set', 'result of handle_switches');

    my @keys   = keys %$want;
    my %single = map {; ref $want->{$_} ? () : ($_ => $want->{$_}) } @keys;
    my %multi  = map {; ref $want->{$_} ? ($_ => $want->{$_}) : () } @keys;

    confess('switches_ok with an empty $want is nonsensical')
      unless %single || %multi;

    cmp_deeply(
      $set,
      all(
        (%single ?     methods(%single) : ()),
        (%multi  ? listmethods(%multi) : ()),
      ),
      "methods on SwitchBox::Set act as expected",
    );
  };

  return $set;
}

sub errors_ok ($self, $str, $want, $desc) {
  my ($switches, $error) = String::Switches::parse_switches($str);

  confess("input string did not parse") unless $switches;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  subtest "errors_ok: $desc" => sub {
    eval {
      $self->handle_switches($switches);
    };

    my $error = $@;

    return fail("handle_switches did not die")
      unless $error;

    isa_ok($error, 'Synergy::SwitchBox::Error', 'result of handle_switches');

    if ($want->{structs}) {
      my @structs = $error->as_structs;

      cmp_deeply(
        \@structs,
        bag($want->{structs}->@*),
        "got the expected error structs",
      );
    }

    diag "S: $_" for $error->as_sentences;

    if ($want->{sentences}) {
      my @sentences = $error->as_sentences;

      cmp_deeply(
        \@sentences,
        bag($want->{sentences}->@*),
        "got the expected error sentences",
      );
    }
  };
}

no Moose;
1;
