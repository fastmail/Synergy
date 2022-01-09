use v5.28.0;
use warnings;
package Synergy::DiagnosticHandler;

use utf8;

package Synergy::DiagnosticHandler::Compartment {
  use v5.28.0;
  use warnings;
  use experimental qw(signatures);

  sub _evaluate ($S, $code) {
    my $result = eval $code;
    if ($@) {
      return (undef, $@);
    }

    return ($result, undef);
  }
}

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS;

use Synergy::Logger '$Logger';
use Synergy::TextThemer;

use List::Util qw(max);

use Term::ANSIColor qw(colored);

has color_scheme => (
  is  => 'ro',
  isa => 'Str',
);

has theme => (
  is    => 'ro',
  lazy  => 1,
  handles   => [ qw(
    _format_box
    _format_wide_box
    _format_notice
  ) ],
  default   => sub ($self) {
    return Synergy::TextThemer->from_name($self->color_scheme)
      if $self->color_scheme;

    return Synergy::TextThemer->null_themer;
  },
);

has hub => (
  is => 'ro',
  required => 1,
  weak_ref => 1,
);

has stream => (
  is => 'ro',
  required => 1,
);

has allow_eval => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

sub _display_message ($self, $text, $title = undef) {
  my $output = $self->_format_box($text, $title);
  $self->stream->write($output);
  return;
}

sub _display_wide_message ($self, $text, $title = undef) {
  my $output = $self->_format_wide_box($text, $title);
  $self->stream->write($output);
  return;
}

my %HELP;
$HELP{''} = <<'EOH';
You're using the Console channel, which is generally used for testing or
diagnostics.  You can just type a message and hit enter.  Some funky
options exist to aid testing.

You can use "/help TOPIC" to read more about topics.

Help topics:

  diag    - commands for inspecting the Synergy configuration
  nlist   - print a list of all notifiers, counted by name/class
  ntree   - print a tree of all notifiers

EOH

$HELP{diag} = <<'EOH';
Some commands exist to let you learn about the running Synergy.  These will
probably change over time.

  /channels - print the registered channels
  /reactors - print the registered reactors
  /users    - print unknown users

  /config   - print a summary of top-level Synergy configuration
  /http     - print a summary of registered HTTP endpoints

  /eval     - evaluate a Perl string, if enabled; $S refers to the hub
EOH

$HELP{eval} = <<'EOH';
If enabled, the /eval command will evaluate its argument as a string of Perl
code.  The variable $S will refer to the active Synergy hub.  The result (or
the exception thrown) will be pretty-printed.

Obviously: caveat evaluator!
EOH

sub _help_for ($self, $arg) {
  $arg = defined $arg ? lc $arg : '';

  my $help = $HELP{ lc $arg };
  return $help;
}

sub _diagnostic_cmd_help ($self, $arg) {
  my $help = $self->_help_for($arg);

  unless ($help) {
    $self->_display_message("No help on that topic!");
    return;
  }

  $self->_display_message($help);
  return;
}

sub _diagnostic_cmd_config ($self, $arg) {
  my $output = "Synergy Configuration\n\n";

  my $url = sprintf 'http://localhost:%i/', $self->hub->server_port;

  my $width = 8;
  $output .= sprintf "  %-*s - %s\n", $width, 'name', $self->hub->name;
  $output .= sprintf "  %-*s - %s\n", $width, 'http', $url;
  $output .= sprintf "  %-*s - %s\n", $width, 'db',
    $self->hub->env->state_dbfile;

  my $userfile = $self->hub->env->has_user_directory_file
               ? $self->hub->env->user_directory_file
               : "(none)";

  $output .= sprintf "  %-*s - %s\n", $width, 'userfile', $userfile;

  $output .= "\nSee also /channels and /reactors and /users";

  $self->_display_message($output);
}

sub _diagnostic_cmd_http ($self, $arg) {
  my $output = "HTTP Endpoints\n\n";

  my @kv = $self->hub->server->_registrations;
  my $url = sprintf 'http://localhost:%i/', $self->hub->server_port;

  my $width = max map {; length $_->[0] } @kv;

  $output .= sprintf "  %-*s routes to %s\n", $width, $_->[0], $_->[1]
    for sort { $a->[0] cmp $b->[0] } @kv;

  $self->_display_message($output);
}

sub _diagnostic_cmd_channels ($self, $arg) {
  my @channels = sort {; $a->name cmp $b->name } $self->hub->channels;
  my $width    = max map {; length $_->name } @channels;

  my $output = "Registered Channels\n\n";
  $output .= sprintf "  %-*s - %s\n", $width, $_->name, ref($_) for @channels;

  $self->_display_message($output);
}

sub _diagnostic_cmd_reactors ($self, $arg) {
  my @reactors = sort {; $a->name cmp $b->name } $self->hub->reactors;
  my $width    = max map {; length $_->name } @reactors;

  my $output = "Registered Reactors\n\n";
  $output .= sprintf "  %-*s - %s\n", $width, $_->name, ref($_) for @reactors;

  $self->_display_message($output);
}

sub _diagnostic_cmd_users ($self, $arg) {
  my @users = sort {; $a->username cmp $b->username }
              $self->hub->user_directory->all_users;

  my $width = max map {; length $_->username } @users;

  my $output = "Known Users\n\n";
  for my $user (@users) {
    my @status;
    push @status, 'deleted' if $user->is_deleted;
    push @status, 'master'  if $user->is_master;
    push @status, 'virtual' if $user->is_virtual;

    my %ident = map {; @$_ } $user->identity_pairs;

    push @status, map {; "$_!$ident{$_}" } sort keys %ident;

    $output .= sprintf "  %-*s - %s\n",
      $width, $user->username,
      join q{; }, @status;
  }

  $self->_display_message($output);
}

sub _diagnostic_cmd_eval ($self, $arg) {
  unless ($self->allow_eval) {
    $self->_display_message("/eval is not enabled");
    return;
  }

  my ($result, $error) = Synergy::DiagnosticHandler::Compartment::_evaluate(
    $self->hub,
    $arg,
  );

  require Data::Dumper::Concise;

  if ($error) {
    my $display = ref $error      ? Data::Dumper::Concise::Dumper($error)
                : defined $error  ? $error
                :                   '(undef)';

    $self->_display_wide_message($display, 'ERROR');
    return;
  }

  my $display = ref $result     ? Data::Dumper::Concise::Dumper($result)
              : defined $result ? $result
              :                   '(undef)';

  $self->_display_wide_message($display, 'RESULT');
  return;
}

sub _diagnostic_cmd_nlist ($self, $rest) {
  # $rest should be empty but ignore it for now
  my %notifier_count;

  for my $notifier ($self->hub->loop->notifiers) {
    my $key = ref $notifier;

    my $name = $notifier->notifier_name;

    $key .= "/$name" if length $name;

    $notifier_count{$key}++;
  }

  my $width = max map {; length } keys %notifier_count;

  my $msg = q{};
  $msg .= sprintf "%-*s - %4i\n", $width, $_, $notifier_count{$_}
    for sort keys %notifier_count;

  $self->_display_message($msg);
  return;
}

sub _diagnostic_cmd_ntree ($self, $rest) {
  # $rest should be empty but ignore it for now
  my %notifier_count;

  my sub nname ($notifier) {
    my $class = ref $notifier;
    my $name  = $notifier->notifier_name;
    return "$class/$name" if length $name;
    return $class;
  }

  my sub nlist ($notifiers, $indent = q{}) {
    my $str = q{};

    my @sorted_pairs =
      sort {; $a->[0] cmp $b->[0] }
      map  {; [ nname($_), $_ ] } @$notifiers;

    for my $pair (@sorted_pairs) {
      my ($name, $notifier) = @$pair;

      $str .= "$indent$name\n";

      my @children = $notifier->children;
      $str .= __SUB__->(\@children, "  $indent");
    }

    return $str;
  }

  my @roots = grep {; ! $_->parent } $self->hub->loop->notifiers;
  my $msg = nlist(\@roots);

  $self->_display_message($msg);
  return;
}

sub _do_diagnostic_command ($self, $text) {
  return undef unless $text =~ s{\A/}{};

  my ($cmd, $rest) = split /\s+/, $text, 2;

  if (my $code =$self->can("_diagnostic_cmd_$cmd")) {
    $self->$code($rest);
    return 1;
  }

  return undef;
}

sub _display_notice ($self, $text) {
  my $output = $self->_format_notice($text);
  $self->stream->write($output);
  return;
}

1;
