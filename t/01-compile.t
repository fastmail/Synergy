use v5.34.0;
use warnings;

use experimental 'signatures';

use Test::More;

use Future::Utils qw(fmap);
use IO::Async::Loop;
use Module::Runtime qw(require_module);
use Process::Status ();

my @files = `find lib -type f -name '*.pm'`;
chomp @files;

my %only_if = (
  'Synergy::Reactor::Linear'              => [ 'Linear::Client' ],
  'Synergy::Reactor::LinearNotification'  => [ 'Linear::Client' ],
  'Synergy::Reactor::RememberTheMilk'     => [ 'WebService::RTM::CamelMilk' ],
  'Synergy::Reactor::Zendesk'             => [ 'Zendesk::Client' ],
);

my $loop = IO::Async::Loop->new;

my @failures;

my %has_prereq;
for my $prereq_list (values %only_if) {
  for my $prereq (@$prereq_list) {
    $has_prereq{$prereq} //= eval { require_module($prereq) } ? 1 : 0;
  }
}

sub setup_test ($module, $file) {
  if ($only_if{$module}) {
    my @missing = grep {; ! $has_prereq{$_} } $only_if{$module}->@*;
    if (@missing) {
      SKIP: {
        skip "compile test: $file (missing prereqs: @missing)", 1;
      };
      return Future->done;
    }
  }

  $loop->run_process(
    command => "$^X -I lib -c $file > /dev/null",
    capture => [ qw( exitcode stderr ) ],
  )->then(sub ($exitcode, $stderr) {
    my $ps = Process::Status->new($exitcode);

    warn $stderr unless $stderr eq "$file syntax OK\n";

    unless (ok($ps->is_success, "compile test: $file")) {
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

my $f_all = fmap { setup_test($_, $file_for_module{$_}) }
  foreach    => [ sort keys %file_for_module ],
  concurrent => 20;

$f_all->get;

BAIL_OUT("compilation failures in: @failures") if @failures;

done_testing;
