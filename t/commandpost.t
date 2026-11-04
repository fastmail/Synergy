#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;
use Test::Deep;

use Synergy::Test::CommandPost;
use Synergy::X;

subtest "the absolute basics" => sub {
  my $outpost = create_outpost(
    [ command => foo => {} => tail_echoer ],
  );

  my $plan = $outpost->consider_targeted("foo bar");

  $plan->cmp_potential(
    methods(name => 'command-foo', is_exclusive => 1),
    "command foo handles 'foo bar'",
  );

  $plan->cmp_results(
    {
      name    => 'command-foo',
      result  => [ 'bar' ],
    },
  );
};

subtest "aliases" => sub {
  my $outpost = create_outpost(
    [ command => foo => { aliases => [ qw(bar) ] } => tail_echoer ],
  );

  $outpost->consider_targeted("foo bar")->cmp_results(
    { name => 'command-foo', result  => [ 'bar' ] },
  );

  $outpost->consider_targeted("FOO bar")->cmp_results(
    { name => 'command-foo', result  => [ 'bar' ] },
    "commands match case insensitively, but args are not munged",
  );

  # Right now, the name of the reaction comes from the name that matched,
  # rather than the name under which the command was declared.  This isn't
  # really the kind of thing to guarantee, so we'll allow either one here.
  # (In a perfect world, I might always use the declared name, but it's not
  # worth the time to fiddle.) -- rjbs, 2022-01-15
  $outpost->consider_targeted("bar quux")->cmp_results(
    { name => any('command-bar', 'command-foo'), result  => [ 'quux' ] },
  );
};

subtest "matchers and parsers" => sub {
  my sub split_if_matching ($regex) {
    return sub ($, $text, @) {
      return unless $text =~ $regex;
      return [ split //, $text ];
    }
  }

  my $outpost = create_outpost(
    [ responder => demo => { matcher => split_if_matching(q{0}) } => tail_echoer ],
    [ command   => demo => { parser  => split_if_matching(q{9}) } => tail_echoer ],
  );

  $outpost->consider_targeted("gorp")->cmp_potential("we won't react without matches");

  $outpost->consider_targeted("g0rp")->cmp_results(
    { name => 'responder-demo', result => [ qw( g 0 r p ) ] },
    'matcher sub determines args to responder',
  );

  $outpost->consider_targeted("demo g9rp")->cmp_results(
    { name => 'command-demo', result => [ qw( g 9 r p ) ] },
    'parser sub determines args to command',
  );
};

subtest "help subcommand" => sub {
  my sub picky_parser ($, $text, @) {
    Synergy::X->throw_public("I don't like that") if $text =~ /help/;
    return [ $text ];
  }

  my $outpost = create_outpost(
    [ command => foo => { help => "Foo help.", aliases => [ 'oof' ] } => tail_echoer ],
    [ command => picky => { help => "Picky help.", parser => \&picky_parser } => tail_echoer ],
    [ command => nohelp => {} => tail_echoer ],
    [ command => skipped => { skip_help => 1 } => tail_echoer ],
    [ command => literal => { help => "Literal help.", help_subcommand => 0, aliases => [ q{laretil} ] } => tail_echoer ],
  );

  # Run the plan, returning the replies sent along the way.
  my sub replies_to ($text) {
    my $plan    = $outpost->consider_targeted($text);
    my $channel = $plan->event->from_channel;
    $channel->clear_messages;

    my @results = $plan->reaction_results;
    my @replies = map {; $_->{text} } $channel->sent_messages;
    $channel->clear_messages;

    return (\@results, \@replies);
  }

  for my $input ("foo help", "FOO help", "foo HELP", "foo --help", "foo /help", "foo  help  ") {
    my ($results, $replies) = replies_to($input);
    cmp_deeply(
      $results,
      [ { name => 'command-foo-help', result => isa('Future') } ],
      "'$input' is handled by the help subcommand",
    );
    is_deeply($replies, [ "Foo help." ], "...and replies with the help text");
  }

  {
    my ($results, $replies) = replies_to("oof help");
    is(@$results, 1, "'oof help' gets one reaction");
    is_deeply($replies, [ "Foo help." ], "...and an alias gives the real help");
  }

  {
    my ($results, $replies) = replies_to("picky help");
    cmp_deeply(
      $results,
      [ { name => 'command-picky-help', result => isa('Future') } ],
      "help subcommand runs before the parser",
    );
    is_deeply($replies, [ "Picky help." ], "...and replies with the help text");
  }

  $outpost->consider_targeted("nohelp help")->cmp_results(
    { name => 'command-nohelp', result => [ 'help' ] },
    "commands without help get 'help' as input",
  );

  $outpost->consider_targeted("skipped help")->cmp_results(
    { name => 'command-skipped', result => [ 'help' ] },
    "commands with skip_help get 'help' as input",
  );

  $outpost->consider_targeted("literal help")->cmp_results(
    { name => 'command-literal', result => [ 'help' ] },
    "help_subcommand => 0 turns this off",
  );

  $outpost->consider_targeted("laretil help")->cmp_results(
    { name => any(q{command-laretil}, q{command-literal}), result => [ q{help} ] },
    "help_subcommand => 0 applies to aliases, too",
  );

  $outpost->consider_targeted("foo helpful thing")->cmp_results(
    { name => 'command-foo', result => [ 'helpful thing' ] },
    "'help' as a prefix of a longer word is not the help subcommand",
  );

  $outpost->consider_targeted("foo help me")->cmp_results(
    { name => 'command-foo', result => [ 'help me' ] },
    "'help' followed by more words is not the help subcommand",
  );

  $outpost->consider_targeted("foo -h")->cmp_results(
    { name => 'command-foo', result => [ '-h' ] },
    "'-h' is not treated as a request for help",
  );

  $outpost->consider_untargeted("foo help")->cmp_potential(
    "untargeted messages don't get the help subcommand",
  );
};

subtest "COMMAND help is the same as help COMMAND" => sub {
  require Synergy::Tester;

  my $synergy = Synergy::Tester->new_tester({
    reactors => {
      help      => { class => 'Synergy::Reactor::Help' },
      helptest  => { class => 'Synergy::Test::Reactor::HelpTest' },
    },
    default_from => 'stormer',
    users => { stormer => undef },
  });

  my $channel = $synergy->test_channel;

  my sub replies_to ($text) {
    $synergy->run_test_program([[ send => { text => "synergy: $text" } ]]);

    my @reply_texts = map {; $_->{text} } $channel->sent_messages;
    $channel->clear_messages;
    return \@reply_texts;
  }

  my $help_widget = replies_to('help widget');

  cmp_deeply(
    $help_widget,
    [ re(qr{\A\*widget `THING`\*}) ],
    '"help widget" gives the widget help',
  );

  is_deeply(replies_to('widget help'), $help_widget, '"widget help" is the same as "help widget"');
  is_deeply(replies_to('widget --help'), $help_widget, '"widget --help" is too');
  is_deeply(replies_to('widget /help'), $help_widget, '"widget /help" is too');
  is_deeply(replies_to('gadget help'), $help_widget, '...and so is the alias "gadget help"');

  is_deeply(replies_to('widget spin'), [ 'The widget does: spin' ], 'the command still works');

  is_deeply(
    replies_to('parrot help'),
    [ 'Squawk: help' ],
    'help_subcommand => 0 passes "help" to the command',
  );
};

done_testing;
