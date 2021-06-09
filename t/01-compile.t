use strict;
use Test::More;

my @files = `find lib -type f -name '*.pm'`;
chomp @files;

my %to_skip = map {; $_ => 1 } qw(
  Synergy::Reactor::RememberTheMilk
  Synergy::Reactor::Zendesk
);

for my $file (sort @files) {
  my $mod = $file;
  $mod =~ s{^lib/}{};
  $mod =~ s{modules/}{};
  $mod =~ s{/}{::}g;
  $mod =~ s{.pm$}{};

  next if $to_skip{ $mod };

  require_ok $mod or BAIL_OUT("compilation failure: $mod");
}

done_testing;
