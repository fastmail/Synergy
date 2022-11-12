use strict;
use warnings;

use Test::More;

use Capture::Tiny ();
use Process::Status ();

my @files = `find lib -type f -name '*.pm'`;
chomp @files;

my %to_skip = map {; $_ => 1 } qw(
  Synergy::Reactor::RememberTheMilk
  Synergy::Reactor::Zendesk
);

my %allow_fail = map {; $_ => 1 } qw(
  Synergy::Reactor::Linear
  Synergy::Reactor::LinearNotification
);

my @failures;

for my $file (sort @files) {
  my $mod = $file;
  $mod =~ s{^lib/}{};
  $mod =~ s{modules/}{};
  $mod =~ s{/}{::}g;
  $mod =~ s{.pm$}{};

  next if $to_skip{ $mod };

  my $stderr = Capture::Tiny::capture_stderr(
    sub { system("$^X -I lib -c $file > /dev/null") }
  );

  my $ps = Process::Status->new;

  warn $stderr unless $stderr eq "$file syntax OK\n";

  unless (ok($ps->is_success, "compile test: $file")) {
    next if $allow_fail{$mod};

    push @failures, $file;

    # If the user ^C-ed the test, just quit rather than making them do it for
    # every remaining test too.
    if ($ps->signal == POSIX::SIGINT()) {
      diag "caught SIGINT, stopping test";
      last PROGRAM;
    }
  }
}

BAIL_OUT("compilation failures in: @failures") if @failures;

done_testing;
