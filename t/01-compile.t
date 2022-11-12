use v5.34.0;
use warnings;

use experimental 'signatures';

use Test::More;

use IO::Async::Loop;
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

my $loop = IO::Async::Loop->new;

my @failures;
my %future_for;

for my $file (sort @files) {
  my $mod = $file;
  $mod =~ s{^lib/}{};
  $mod =~ s{modules/}{};
  $mod =~ s{/}{::}g;
  $mod =~ s{.pm$}{};

  next if $to_skip{ $mod };

  $future_for{$mod} = $loop->run_process(
    command => "$^X -I lib -c $file > /dev/null",
    capture => [ qw( exitcode stderr ) ],
  )->then(sub ($exitcode, $stderr) {
    delete $future_for{$mod};

    my $ps = Process::Status->new($exitcode);

    warn $stderr unless $stderr eq "$file syntax OK\n";

    unless (ok($ps->is_success, "compile test: $file")) {
      return Future->done if $allow_fail{$mod};

      push @failures, $file;

      # If the user ^C-ed the test, just quit rather than making them do it for
      # every remaining test too.
      if ($ps->signal == POSIX::SIGINT()) {
        diag "caught SIGINT, stopping test";
        kill 'INT', $$;
      }
    }

    Future->done;
  });
}

Future->wait_all(values %future_for)->get;

BAIL_OUT("compilation failures in: @failures") if @failures;

done_testing;
