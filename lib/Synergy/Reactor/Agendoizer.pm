use v5.24.0;
use warnings;
package Synergy::Reactor::Agendoizer;

use utf8;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

# email X [to Y?]
# update agenda X /set foo bar

sub listener_specs {
  return (
    {
      name      => 'create',
      method    => 'handle_create',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /^agenda create\s/i
      },
      help_entries => [
        { title => 'agenda', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
The *agenda* command lets you manage simple agendas.  It's not even much of
a todo list, it's just a way to make a list of items that you'll want to look
at later.  It was made to make it as quick and easy to write down "Hey, I want
to talk to Stormer about this next time we have a call!" as was possible.

• *agenda create `AGENDA`*: create an agenda for yourself
• *agenda list*: list all the agendas you can see
• *agenda for `AGENDA`*: show the items on the given agenda
• *agenda add to `AGENDA`: `ITEM`*: add the given item to an agenda
• *agenda strike from `AGENDA`: `ITEM`*: strike the item from an agenda
• *agenda clear `AGENDA`*: strike everything from an agenda
(great if you've just had your meeting!)
• *agenda delete `AGENDA`*: delete an agenda entirely

You can also add items with *[`AGENDA`] `ITEM`* and strike them with
*[-`AGENDA`] `ITEM`*.  When adding items this way, you can write `...` for the
item and then provide a bullet list on subsequent lines, each item of which
will be added.

See also *help agenda sharing*.
EOH

        { title => 'agenda sharing', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg }
Agenda names are short runs of letters and numbers.  By default `huddle` means
your agenda named "huddle", but you can refer to someone else's agendas by
using their username, like `rjbs/travel`.

Normally, you can't see anyone else's agendas, but agendas can be shared with
individual users or with everyone.  There are three levels of permission:

• read: the sharee can see the agenda and its contents
• add: the sharee can add items to the agenda
• strike: the sharee can strike items from the agenda

These commands manage agenda sharing:

• *agenda share `AGENDA` with `USER`:`PERM`*: updates a user's permissions for
an agenda; you can supply multiple user/permission pairs, separated by spaces,
and if there is no colon in the pair, the default permission is `add`.  To
share with everyone provide the username `*`.
• *agenda unshare `AGENDA`*: totally unshare an agenda
• *agenda sharing for `AGENDA`*: shows what permissions exist
EOH
      ],
    },
    {
      name      => 'list',
      method    => 'handle_list',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda list\z/i
      },
    },
    {
      name      => 'for',
      method    => 'handle_for',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda for\s/i
      },
    },
    {
      name      => 'add',
      method    => 'handle_add',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted
        && ($e->text =~ /\Aagenda add\s/i || $e->text =~ /^\[[^-\]]+\]\s/)
      },
    },
    {
      name      => 'strike',
      method    => 'handle_strike',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted
        && ($e->text =~ /\Aagenda strike\s/i || $e->text =~ /^\[-[^\]]+\]\s/)
      },
    },
    {
      name      => 'clear',
      method    => 'handle_clear',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda clear\s/i
      },
    },
    {
      name      => 'delete',
      method    => 'handle_delete',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda delete\s/i
      },
    },
    {
      name      => 'share',
      method    => 'handle_share',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda share \S+ with\s/i
      },
    },
    {
      name      => 'unshare',
      method    => 'handle_unshare',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda unshare\s/i
      },
    },
    {
      name      => 'sharing',
      method    => 'handle_sharing',
      exclusive => 1,
      predicate => sub ($, $e) {
        $e->was_targeted && $e->text =~ /\Aagenda sharing\s/i
      },
    },
  );
}

sub state ($self) {
  return {
    useragendas => $self->_useragendas,
  };
}

after register_with_hub => sub ($self, @) {
  my $state = $self->fetch_state;

  if ($state && $state->{useragendas}) {
    $self->set_useragendas_from_storage($state->{useragendas});
  }
};

# agenda storage:
#   USER => {
#     FLAT_NAME => {
#      name  => EXACT_NAME,
#      share => { username => PERMS, '' => PERMS } # empty str is "everyone"
#      items => [ { text => ..., added_at => ..., ??? }, ... ]
#      description => TEXT, # what even is this agenda?

has useragendas => (
  reader  => '_useragendas',
  writer  => 'set_useragendas_from_storage',
  default => sub {  {}  },
);

sub agendas_for ($self, $user) {
  $self->_useragendas->{ $user->username } //= {};
}

sub agendas_shared_with ($self, $user) {
  my $username    = $user->username;
  my $useragendas = $self->_useragendas;

  my %return;
  for my $sharer (grep {; $_ ne $username } keys %$useragendas) {
    for my $agenda (keys $useragendas->{$sharer}->%*) {
      $return{"$sharer/$agenda"} = $useragendas->{$sharer}{$agenda};
    }
  }

  return \%return;
}

my $agendaname_re = qr{[0-9a-z]+}i;

sub handle_create ($self, $event) {
  my $text = $event->text;

  $event->mark_handled;

  my ($name) = $text =~ /\Aagenda create ($agendaname_re)\z/;

  unless ($name) {
    if ($text =~ /\Aagenda create ([\pl\pn]+)\z/) {
      return $event->error_reply("I acknoweldge and appreciate that you are very clever, but we speak ASCII in the Agendoizer.");
    }
    return $event->error_reply("It's *agenda create `NAME`*, and the name has to be just numbers and letters.");
  }

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my $agendas = $self->agendas_for($event->from_user);

  if ($agendas->{ fc $name }) {
    return $event->error_reply("This is awkward:  you already have an agenda with that name.");
  }

  $agendas->{ fc $name } = { name => $name, share => {}, items => [] };

  $self->save_state;

  $event->reply("I've created a new agenda for you.");

  return;
}

sub handle_list ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my $agendas = {
    $self->agendas_for($event->from_user)->%*,
    $self->agendas_shared_with($event->from_user)->%*
  };

  my @to_list = $event->is_public
              ? (grep {; $agendas->{$_}{share}{''} } keys %$agendas)
              : keys %$agendas;

  unless (@to_list) {
    if (@to_list != keys %$agendas) {
      return $event->reply("The only agendas you can see are private.");
    }

    return $event->reply("You don't have any available agendas.");
  }

  my $text = "Agendas you can see:\n"
           . join qq{\n}, map {; "• $_" } sort @to_list;

  if (@to_list != keys %$agendas) {
    $text .= "\n…and some private agendas not shown here.";
  }

  $event->reply($text);
}

sub _best_of ($p1, $p2) {
  return $p1 if ! defined $p2;
  return $p2 if ! defined $p1;

  for my $opt (qw(strike add read)) {
    return $opt if $p1 eq $opt || $p2 eq $opt;
  }

  return undef;
}

my %PERM = (
  admin   => { map {; $_ => 1 } qw( read add strike admin ) },
  strike  => { map {; $_ => 1 } qw( read add strike       ) },
  add     => { map {; $_ => 1 } qw( read add              ) },
  read    => { map {; $_ => 1 } qw( read                  ) },
);

sub resolve_agenda_and_user ($self, $str, $user) {
  my ($upart, $lpart) = $str =~ m{/} ? (split m{/}, $str, 2) : ('me', $str);

  my $result = {};

  return $result unless $result->{owner}  = $self->resolve_name($upart, $user);
  return $result unless $result->{agenda} = $self->agendas_for($result->{owner})->{ fc $lpart };

  my $perms = $result->{owner}->username eq $user->username
            ? 'admin'
            : _best_of(
                $result->{agenda}{share}{''},
                $result->{agenda}{share}{ $user->username }
              );

  return { owner => $result->{owner} } unless $perms;

  $result->{perms} = $PERM{ $perms };

  return $result;
}

sub handle_for ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my $username = $event->from_user->username;

  my ($arg) = $event->text =~ /\Aagenda for (\S+)\s*\z/;

  unless (length $arg) {
    return $event->error_reply("It's *agenda for NAME* where the name is one of your agenda names or username/agendaname for a agenda shared with you.");
  }

  my $agrez = $self->resolve_agenda_and_user($arg, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  if (
    $event->is_public
    && ! $agenda->{share}{''}
    && ! $agrez->{perms}{admin}
  ) {
    # Okay, it's weird, but my view is:  you can add or remove specific stuff
    # on a private agenda in public and it's not so bad, but listing its contents
    # all out would be bad. -- rjbs, 2019-08-14
    $event->error_reply("Sorry, I couldn't find that agenda.");
    my $well_actually = sprintf "Actually, I declined to talk about %s/%s in public, because it's a private agenda!",
      $agrez->{owner}->username,
      $agenda->{name};
    $event->private_reply($well_actually, { slack => $well_actually });
  }

  my $items = $agenda->{items};

  unless (@$items) {
    return $event->reply("I found that agenda, but it's empty!");
  }

  my $text = "Items on that agenda:\n";
  $text .= join qq{\n},
           map  {; "• $_->{text}" }
           sort { $a->{added_at} <=> $b->{added_at} } @$items;

  $event->reply($text);
}

sub handle_add ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname, $text)
    = $event->text =~ /\A\[/
    ? $event->text =~ /\A\[([^\]]+)\]\s+(.+)\z/s
    : $event->text =~ /\Aagenda add to\s+([^\s:]+):?\s+(.+)\z/s;

  unless (length $text) {
    return $event->error_reply("It's *agenda add to AGENDA: ITEM*.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agrez->{agenda};

  return $event->error_reply("Sorry, you can't add to that agenda.")
    unless $agrez->{owner}->username eq $event->from_user->username
    or $agrez->{perms}{add};

  my @lines = grep /\S/, split /\v+/, $text;

  if (@lines > 1) {
    unless (grep {; $_ eq '...' or $_ eq '…' } shift @lines) {
      return $event->error_reply(
        q{Multi-line agenda adds need to have "..." as the first line.}
      );
    }

    unless (@lines == grep {; s/\A[*•]\s+// } @lines) {
      return $event->error_reply(
        q{Multi-line agenda adds need to have a bullet for every item.}
      );
    }

  }

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agrez->{agenda};

  push $agrez->{agenda}->{items}->@*, map {;
    {
      added_at => time,
      added_by => $event->from_user->username,
      text     => $_,
    }
  } @lines;

  $self->save_state;

  return $event->reply("I added it to the agenda!");
}

sub handle_strike ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname, $text)
   = $event->text =~ /\A\[/
   ? $event->text =~ /\A\[-([^\]]+)\]\s+(.+)\z/s
   : $event->text =~ /\Aagenda strike from\s+([^\s:]+):?\s+(.+)\z/s;

  unless (length $text) {
    return $event->error_reply("It's *agenda strike from AGENDA: ITEM*.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  return $event->error_reply("Sorry, you can't strike from that agenda.")
    unless $agrez->{perms}{strike};

  my $to_strike = grep {; fc $_->{text} eq fc $text } $agenda->{items}->@*;

  unless ($to_strike) {
    return $event->error_reply("Sorry, I don't see an item like that on the agenda.");
  }

  $agenda->{items}->@* = grep {; fc $_->{text} ne fc $text } $agenda->{items}->@*;

  $self->save_state;

  my $reply = "I struck that from the agenda!";
  $reply .= "  It was on there $to_strike times." if $to_strike > 1;

  return $event->reply($reply);
}

sub handle_clear ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname) = $event->text =~ /\Aagenda clear\s+(\S+)\s*\z/;

  unless (length $agendaname) {
    return $event->error_reply("It's *agenda clear AGENDA*.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  return $event->error_reply("Sorry, you can't strike items from that agenda.")
    unless $agrez->{perms}{strike};

  $agenda->{items}->@* = ();

  $self->save_state;

  return $event->reply("I cleared the agenda!");
}

# delete
sub handle_delete ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname) = $event->text =~ /\Aagenda delete\s+(\S+)\s*\z/;

  unless (length $agendaname) {
    return $event->error_reply("It's *agenda delete AGENDA*.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  return $event->error_reply("Sorry, you can only delete your own agendas.")
    unless $agrez->{perms}{admin};

  delete $self->_useragendas->{ $event->from_user->username }{ fc $agenda->{name} };

  $self->save_state;

  return $event->reply("I deleted the agenda!");
}

sub handle_share ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname, $args) = $event->text =~ /\Aagenda share (\S+) with\s+(.+)\z/;

  unless (length $args) {
    return $event->error_reply("I didn't understand how you wanted to share.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  return $event->error_reply("Sorry, you can only share your own agendas.")
    unless $agrez->{perms}{admin};

  my @instructions = map  {; [ split /:/, $_ ] }
                     grep {; length }
                     split /\s+/, $args;

  unless (@instructions) {
    return $event->error_reply("I didn't understand how you wanted to share.");
  }

  my %plan;
  my %error;

  for my $instruction (@instructions) {
    my $perm = $instruction->[1] // 'add';

    my $sharee;

    if (! length $instruction->[0]) {
      return $event->error_reply("Your share request didn't make sense to me.");
    } elsif ($instruction->[0] eq '*') {
      $sharee = '';
    } else {
      my $who  = $self->resolve_name($instruction->[0], $event->from_user);
      $error{"I don't know who `$who` is."} = 1 unless $who;

      $sharee = $who->username if $who;

      $error{"Sharing with yourself is weird and I won't allow it."} = 1
        if $who && $who->username eq $event->from_user->username;
    }

    # TTP: Totally tragic perm.
    $error{"I don't know how to share for `$perm`."} = 1
      unless exists $PERM{$perm};

    $error{"You can't share admin permissions."} = 1
      if $perm eq 'admin';

    $error{"You mentioned $sharee more than once!"} = 1
      if $plan{$sharee};

    $plan{$sharee} = $perm;
  }

  if (%error) {
    return $event->error_reply(
      join q{  },
      "I'm not sharing that agenda:  ",
      sort keys %error,
    );
  }

  $agenda->{share}->%* = ($agenda->{share}->%*, %plan);

  $self->save_state;

  return $event->reply("I have updated permissions on that agenda!");
}

sub handle_unshare ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname) = $event->text =~ /\Aagenda unshare (\S+)\z/;

  unless (length $agendaname) {
    return $event->error_reply("I didn't understand what you wanted to unshare.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  return $event->error_reply("Sorry, you can only unshare your own agendas.")
    unless $agrez->{perms}{admin};

  $agenda->{share} = {};

  $self->save_state;

  return $event->reply("That agenda is now entirely private.");
}

sub handle_sharing ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("I don't know who you are, so I'm not going to do that.");
    return;
  }

  my ($agendaname) = $event->text =~ /\Aagenda sharing for (\S+)\z/;

  unless (length $agendaname) {
    return $event->error_reply("To see sharing for an agenda, it's *agenda sharing for `AGENDA`*.");
  }

  my $agrez = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $agrez->{owner};

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless my $agenda = $agrez->{agenda};

  unless (keys $agenda->{share}->%*) {
    return $event->reply("That agenda isn't shared at all.");
  }

  my $reply = sprintf "Sharing for %s/%s is as follows:\n",
    $agrez->{owner}->username,
    $agenda->{name};

  $reply .= join qq{\n},
            map {;
              sprintf "• *%s* can *%s* items",
                (length $_ ? $_ : 'all users'),
                $agenda->{share}{$_} }
            sort { fc $a cmp fc $b }
            keys $agenda->{share}->%*;

  return $event->reply($reply);
}

1;
