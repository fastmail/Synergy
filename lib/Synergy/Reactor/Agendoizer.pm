use v5.24.0;
use warnings;
package Synergy::Reactor::Agendoizer;

use utf8;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

# remove from list X: T
# email X [to Y?]
# update list X /set foo bar
# share list X with Y

sub listener_specs {
  return (
    {
      name      => 'new_list',
      method    => 'handle_new',
      exclusive => 1,
      predicate => sub ($, $e) { $e->was_targeted && $e->text =~ /^(?:new|add) list\s/i },
    },
    {
      name      => 'list_of_lists',
      method    => 'handle_list_of_lists',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Alists\z/i
      },
    },
    {
      name      => 'list_contents',
      method    => 'handle_list_contents',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Alist\s/i
      },
    },
    {
      name      => 'add_to_list',
      method    => 'handle_add_to_list',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aadd to\s/i
      },
    },
    {
      name      => 'remove_from_list',
      method    => 'handle_remove_from_list',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aremove from\s/i
      },
    },
    {
      name      => 'clear_list',
      method    => 'handle_clear_list',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aclear list\s/i
      },
    },
    {
      name      => 'delete_list',
      method    => 'handle_delete_list',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Adelete list\s/i
      },
    },
  );
}

sub state ($self) {
  return {
    userlists => $self->_userlists,
  };
}

after register_with_hub => sub ($self, @) {
  my $state = $self->fetch_state;

  if ($state && $state->{userlists}) {
    $self->set_userlists_from_storage($state->{userlists});
  }
};

# list storage:
#   USER => {
#     FLAT_NAME => {
#      name  => EXACT_NAME,
#      share => { username => PERMS, '' => PERMS } # empty str is "everyone"
#      items => [ { text => ..., added_at => ..., ??? }, ... ]
#      description => TEXT, # what even is this list?

has userlists => (
  reader  => '_userlists',
  writer  => 'set_userlists_from_storage',
  default => sub {  {}  },
);

sub lists_for ($self, $user) {
  $self->_userlists->{ $user->username } //= {};
}

sub lists_shared_with ($self, $user) {
  my $username  = $user->username;
  my $userlists = $self->_userlists;

  my %return;
  for my $sharer (grep {; $_ ne $username } keys %$userlists) {
    for my $list (keys $userlists->{$sharer}->%*) {
      $return{"$sharer/$list"} = $userlists->{$sharer}{$list};
    }
  }

  return \%return;
}

my $listname_re = qr{[0-9a-z]+}i;

sub handle_new ($self, $event) {
  my $text = $event->text;

  $event->mark_handled;

  my ($name) = $text =~ /\A(?:new|add) list named ($listname_re)\s*\z/;

  unless ($name) {
    return $event->error_reply("It's *new list named `NAME`*, and the name has to be just numbers and English alphabet letters.");
  }

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  if (fc $name eq 'list' or fc $name eq 'lists') {
    return $event->error_reply("For the sake of everybody sanity, I'm not going to let you call your list \F$name!");
  }

  my $lists = $self->lists_for($event->from_user);

  if ($lists->{ fc $name }) {
    return $event->error_reply("This is awkward:  you already have a list with that name.");
  }

  $lists->{ fc $name } = { name => $name, share => {}, items => [] };

  $self->save_state;

  $event->reply("I've created a new list for you.");

  return;
}

sub handle_list_of_lists ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my $lists = {
    $self->lists_for($event->from_user)->%*,
    $self->lists_shared_with($event->from_user)->%*
  };

  my @to_list = $event->is_public
              ? (grep {; $lists->{$_}{share}{''} } keys %$lists)
              : keys %$lists;

  unless (@to_list) {
    if (@to_list != keys %$lists) {
      return $event->reply("The only lists you can see are private.");
    }

    return $event->reply("You don't have any available lists.");
  }

  my $text = "Lists you can see:\n"
           . join qq{\n}, map {; "* $_" } sort @to_list;

  if (@to_list != keys %$lists) {
    $text .= "\n…and some private lists not shown here.";
  }

  $event->reply($text);
}

sub resolve_list_and_user ($self, $str, $user) {
  my ($upart, $lpart) = $str =~ m{/} ? (split m{/}, $str, 2) : ('me', $str);

  return (undef, undef) unless my $who = $self->resolve_name($upart, $user);

  my $list = $self->lists_for($who)->{ fc $lpart };

  undef $list
    if $list
    && $who->username ne $user->username
    && ! $list->{share}{$user->username};

  return ($who, $list);
}

sub handle_list_contents ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my $username = $event->from_user->username;

  my ($arg) = $event->text =~ /\Alist\s+(\S+)\s*\z/;

  unless (length $arg) {
    return $event->error_reply("It's *list NAME* where the name is one of your list names or username/listname for a list shared with you.");
  }

  my ($owner, $list) = $self->resolve_list_and_user($arg, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose list you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that list.")
    unless $list;

  if (
    $event->is_public
    && ! $list->{share}{''}
    && $owner->username ne $username
  ) {
    # Okay, it's weird, but my view is:  you can add or remove specific stuff
    # on a private list in public and it's not so bad, but listing its contents
    # all out would be bad. -- rjbs, 2019-08-14
    $event->error_reply("Sorry, I couldn't find that list.");
    my $well_actually = sprintf "Actually, I declined to talk about %s/%s in public, because it's a private list!", $owner->username, $list->{name};
    $event->private_reply($well_actually, { slack => $well_actually });
  }

  my $items = $list->{items};

  unless (@$items) {
    return $event->reply("I found that list, but it's empty!");
  }

  my $text = "Items on that list:\n";
  $text .= join qq{\n},
           map  {; "* $_->{text}" }
           sort { $a->{added_at} <=> $b->{added_at} } @$items;

  $event->reply($text);
}

sub handle_add_to_list ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($listname, $text) = $event->text =~ /\Aadd to\s+([^\s:]+):?\s+(.+)\z/;

  unless (length $text) {
    return $event->error_reply("It's *add to LIST: WHAT*.");
  }

  my ($owner, $list) = $self->resolve_list_and_user($listname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose list you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that list.")
    unless $list;

  return $event->error_reply("Sorry, you can't write to that list.")
    unless $owner->username eq $event->from_user->username
    or $list->{share}{ $event->from_user->username } =~ /\A(?:write|delete)\z/;

  push $list->{items}->@*, {
    added_at => time,
    added_by => $event->from_user->username,
    text     => $text,
  };

  $self->save_state;

  return $event->reply("I added it to the list!");
}

sub handle_remove_from_list ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($listname, $text) = $event->text =~ /\Aremove from\s+([^\s:]+):?\s+(.+)\z/;

  unless (length $text) {
    return $event->error_reply("It's *remove from LIST: WHAT*.");
  }

  my ($owner, $list) = $self->resolve_list_and_user($listname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose list you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that list.")
    unless $list;

  return $event->error_reply("Sorry, you can't delete from that list.")
    unless $owner->username eq $event->from_user->username
    or $list->{share}{ $event->from_user->username } eq 'delete';

  my $to_delete = grep {; fc $_->{text} eq fc $text } $list->{items}->@*;

  unless ($to_delete) {
    $event->error_reply("Sorry, I don't see an item like that on the list.");
  }

  $list->{items}->@* = grep {; fc $_->{text} ne fc $text } $list->{items}->@*;

  $self->save_state;

  my $reply = "I delete that from the list!";
  $reply .= "  It was on there $to_delete times." if $to_delete > 1;

  return $event->reply($reply);
}

sub handle_clear_list ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($listname) = $event->text =~ /\Aclear list\s+(\S+)\s*\z/;

  unless (length $listname) {
    return $event->error_reply("It's *clear list LIST*.");
  }

  my ($owner, $list) = $self->resolve_list_and_user($listname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose list you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that list.")
    unless $list;

  return $event->error_reply("Sorry, you can't delete from that list.")
    unless $owner->username eq $event->from_user->username
    or $list->{share}{ $event->from_user->username } eq 'delete';

  $list->{items}->@* = ();

  $self->save_state;

  return $event->reply("I cleared the list!");
}

sub handle_delete_list ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($listname) = $event->text =~ /\Adelete list\s+(\S+)\s*\z/;

  unless (length $listname) {
    return $event->error_reply("It's *delete list LIST*.");
  }

  my ($owner, $list) = $self->resolve_list_and_user($listname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose list you want.")
    unless $owner;

  return $event->error_reply("Sorry, you can only delete your own lists.")
    unless $owner->username eq $event->from_user->username;

  return $event->error_reply("Sorry, I can't find that list.")
    unless $list;

  delete $self->_userlists->{ $event->from_user->username }{ fc $list->{name} };

  $self->save_state;

  return $event->reply("I deleted the list!");
}

1;
