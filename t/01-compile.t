use v5.34.0;
use warnings;

use experimental 'signatures';

use Test::More;

use Future::Utils qw(fmap);
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

sub spawn_process ($module, $file) {
  $loop->run_process(
    command => "$^X -I lib -c $file > /dev/null",
    capture => [ qw( exitcode stderr ) ],
  )->then(sub ($exitcode, $stderr) {
    my $ps = Process::Status->new($exitcode);

    warn $stderr unless $stderr eq "$file syntax OK\n";

    unless (ok($ps->is_success, "compile test: $file")) {
      return Future->done if $allow_fail{$module};

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

my %file_for_module = map {;
  (s{^lib/}{}r =~ s{modules/}{}r =~ s{/}{::}gr =~ s{.pm$}{}r) => $_
} @files;

my $f_all = fmap { spawn_process($_, $file_for_module{$_}) }
  foreach    => [ grep {; ! $to_skip{$_} } keys %file_for_module ],
  concurrent => 20;

$f_all->get;

BAIL_OUT("compilation failures in: @failures") if @failures;

done_testing;
