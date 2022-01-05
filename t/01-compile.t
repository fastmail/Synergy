use strict;
use Test::More;

my @files = `find lib -type f -name '*.pm'`;
chomp @files;

my %to_skip = map {; $_ => 1 } qw(
  Synergy::Reactor::RememberTheMilk
  Synergy::Reactor::Zendesk
);

my %allow_fail = map {; $_ => 1 } qw(
  Synergy::Reactor::Linear
);


for my $file (sort @files) {
  my $mod = $file;
  $mod =~ s{^lib/}{};
  $mod =~ s{modules/}{};
  $mod =~ s{/}{::}g;
  $mod =~ s{.pm$}{};

  next if $to_skip{ $mod };

  next if require_ok $mod;

  unless ($allow_fail{$mod}) {
    BAIL_OUT("compilation failure: $mod");
  }
}

done_testing;
