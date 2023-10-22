use v5.32.0;
use warnings;

package Test::SwitchBox;
use Moose;
extends 'Synergy::SwitchBox';

use experimental qw(signatures);

use String::Switches ();
use Test::Deep ':v1';
use Test::More;

sub switches_ok ($self, $str, $want, $desc) {
  my ($switches, $error) = String::Switches::parse_switches($str);

  confess("input string did not parse") unless $switches;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  subtest "switches_ok: $desc" => sub {
    my $set = $self->handle_switches($switches);

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

    my @structs = $error->as_structs;

    cmp_deeply(
      \@structs,
      bag(@$want),
      "got the expected error structs",
    );
  };
}

no Moose;
1;
