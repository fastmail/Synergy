use v5.32.0;
use warnings;
package Synergy::Reactor::Preferences;

use Moose;
use Try::Tiny;
use Synergy::Logger '$Logger';
use utf8;

with 'Synergy::Role::Reactor::CommandPost';

use Future::AsyncAwait;
use Synergy::CommandPost;
use Synergy::Util qw(reformat_help);

use experimental qw(signatures);
use namespace::clean;

help preferences => reformat_help(<<~"EOH");
  Different components of Synergy provide user-level preferences that range
  from the vital (like your real name) to the … less vital.

  To know what preferences you can or have already set, try:

  • *list all preferences*: this, obviously, lists all preferences you can set
  • *help preference `PREF`*: show help for the preference
  • *dump my preferences*: this shows you all your preferences
  • *dump preferences for `USER`*: see another user's prefs

  To set your preferences:

  • *set my `PREF` to `VALUE`*: set a preference
  • *clear my `PREF`*: unset a preference and go back to the default

  If you're an administrator, you can also…

  • *set `USER`'s `PREF` to `VALUE`*: set another user's preferences
  • *clear `USER`'s `PREF`*: unset some other user's preference
  EOH

command set => { # allow_empty_help => 1,  # provided by preferences above
} => async sub ($self, $event, $rest) {
  my ($who, $pref_name, $pref_value) =
    $event->text =~ m{\A set \s+ (my|\w+[’']s) \s+      # set my
                      ([-_a-z0-9]+  \.   [-_a-z0-9]+)   # component.pref
                      (?:\s+to|:)? \s+ (.*)             # (to or :) value
                     }ix;

  unless ($who) {
    return await $event->error_reply("I didn't understand that use of set.");
  }

  return await $self->_set_pref($event, $who, $pref_name, $pref_value);
};

command clear => { # allow_empty_help => 1,  # provided by preferences above
} => async sub ($self, $event, $rest) {
  my ($who, $pref_name, $rest) =
    $event->text =~ m{\A clear \s+ (my|\w+[’']s) \s+    # set my
                      ([-_a-z0-9]+  \.  [-_a-z0-9]+)    # component.pref
                      \s* (.+)?
                     }ix;

  unless ($who) {
    return await $event->error_reply("I didn't understand that use of clear.");
  }

  return $event->error_reply("You can't pass a value to 'clear'")
    if $rest;

  return await $self->_set_pref($event, $who, $pref_name, undef);
};

responder list => { # allow_empty_help => 1,  # provided by preferences above
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($self, $text, @) {
    return [] if $text =~ /\Alist(\s+all)?\s+(settings|pref(erence)?s)\s*\z/i;
    return;
  },
} => async sub ($self, $event) {
  $event->mark_handled;

  my @sources = map {; [ $_->preference_namespace, $_ ] }
    $self->hub->user_directory,
    grep {; $_->does('Synergy::Role::HasPreferences') } $self->hub->reactors;

  my $text = qq{*Known preferences are:*\n};
  for my $source (sort { $a->[0] cmp $b->[0] } @sources) {
    my ($ns, $has_pref) = @$source;

    my $help = $has_pref->preference_help;
    for my $key (sort keys %$help) {
      $text .= sprintf "*%s.%s* - %s\n",
        $ns,
        $key,
        $help->{$key}{description} // 'mystery preference';
    }
  }

  chomp $text;
  return await $event->reply($text);
};

responder dump => { # allow_empty_help => 1,  # provided by preferences above
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($self, $text, @) {
    return [ 'me' ] if $text =~ /\Apref(erence)?s\z/in;
    return [ 'me' ] if $text =~ /\A(dump|show)(\s+my)?\s+(settings|pref(erence)?s)/in;
    return [ $1   ] if $text =~ /\A(?:dump|show)\s+(?:settings|pref(?:erence)?s)\s+for\s+(\s+)\s*\z/i;
    return;
  },
} => async sub ($self, $event, $who) {
  $event->mark_handled;

  my $for_user = $self->resolve_name($who, $event->from_user);

  unless ($for_user) {
    return await $event->error_reply(qq!I don't know who "$who" is!);
  }

  my @pref_strings;
  my $hub = $self->hub;

  my @components = map  {; $_->[0]                                   }
                   sort {; $a->[1] cmp $b->[1]                       }
                   map  {; [ $_, fc $_->preference_namespace ]       }
                   grep {; $_->does('Synergy::Role::HasPreferences') }
                   ($hub->user_directory, $hub->channels, $hub->reactors);

  for my $component (@components) {
    for my $pref_name (sort $component->preference_names) {
      my $full_name = $component->preference_namespace . q{.} . $pref_name;
      my $desc      = await $component->describe_user_preference($for_user, $pref_name);
      $desc //= '(error)';

      push @pref_strings, "$full_name: $desc";
    }
  }

  my $prefs = join "\n", @pref_strings;
  my $name = $for_user->username;

  return await $event->reply("Preferences for $name: ```$prefs```");
};

async sub _set_pref ($self, $event, $who, $full_name, $pref_value) {
  return unless $who;
  $who =~ s/[’']s$//;

  my $user = $self->hub->user_directory->resolve_name($who, $event->from_user);
  return await $event->error_reply("Sorry, I couldn't find a user for <$who>")
    unless $user;

  my ($comp_name, $pref_name) = split /\./, $full_name, 2;

  my $component;
  try {
    $component = $self->hub->component_named($comp_name);
  } catch {
    $self->_error_no_prefs($event, $comp_name)
      if /Could not find channel or reactor/;
  };

  return unless $component;

  if ($user != $event->from_user && ! $event->from_user->is_master) {
    return await $event->error_reply(
      "Sorry, only master users can set preferences for other people"
    );
  }

  return $self->_error_no_prefs($event, $comp_name)
    unless $component->can('set_preference');

  await $component->set_preference($user, $pref_name, $pref_value, $event);

  return;
}

sub _error_no_prefs ($self, $event, $component) {
  $event->mark_handled;
  $event->error_reply("<$component> does not appear to have preferences");
}

1;
