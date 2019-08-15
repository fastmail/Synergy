use v5.24.0;
use warnings;
package Synergy::Reactor::Agendoizer;

use utf8;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

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
           . join qq{\n}, map {; "* $_" } sort @to_list;

  if (@to_list != keys %$agendas) {
    $text .= "\n…and some private agendas not shown here.";
  }

  $event->reply($text);
}

sub resolve_agenda_and_user ($self, $str, $user) {
  my ($upart, $lpart) = $str =~ m{/} ? (split m{/}, $str, 2) : ('me', $str);

  return (undef, undef) unless my $who = $self->resolve_name($upart, $user);

  my $agenda = $self->agendas_for($who)->{ fc $lpart };

  undef $agenda
    if $agenda
    && $who->username ne $user->username
    && ! $agenda->{share}{$user->username};

  return ($who, $agenda);
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

  my ($owner, $agenda) = $self->resolve_agenda_and_user($arg, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  if (
    $event->is_public
    && ! $agenda->{share}{''}
    && $owner->username ne $username
  ) {
    # Okay, it's weird, but my view is:  you can add or remove specific stuff
    # on a private agenda in public and it's not so bad, but listing its contents
    # all out would be bad. -- rjbs, 2019-08-14
    $event->error_reply("Sorry, I couldn't find that agenda.");
    my $well_actually = sprintf "Actually, I declined to talk about %s/%s in public, because it's a private agenda!", $owner->username, $agenda->{name};
    $event->private_reply($well_actually, { slack => $well_actually });
  }

  my $items = $agenda->{items};

  unless (@$items) {
    return $event->reply("I found that agenda, but it's empty!");
  }

  my $text = "Items on that agenda:\n";
  $text .= join qq{\n},
           map  {; "* $_->{text}" }
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
   ? $event->text =~ /\A\[([^\]]+)\]\s+(.+)\z/
   : $event->text =~ /\Aagenda add to\s+([^\s:]+):?\s+(.+)\z/;

  unless (length $text) {
    return $event->error_reply("It's *agenda add to AGENDA: ITEM*.");
  }

  my ($owner, $agenda) = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  return $event->error_reply("Sorry, you can't add to that agenda.")
    unless $owner->username eq $event->from_user->username
    or $agenda->{share}{ $event->from_user->username } =~ /\A(?:write|strike)\z/;

  push $agenda->{items}->@*, {
    added_at => time,
    added_by => $event->from_user->username,
    text     => $text,
  };

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
   ? $event->text =~ /\A\[-([^\]]+)\]\s+(.+)\z/
   : $event->text =~ /\Aagenda strike from\s+([^\s:]+):?\s+(.+)\z/;

  unless (length $text) {
    return $event->error_reply("It's *agenda strike from AGENDA: ITEM*.");
  }

  my ($owner, $agenda) = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  return $event->error_reply("Sorry, you can't strike from that agenda.")
    unless $owner->username eq $event->from_user->username
    or $agenda->{share}{ $event->from_user->username } eq 'strike';

  my $to_strike = grep {; fc $_->{text} eq fc $text } $agenda->{items}->@*;

  unless ($to_strike) {
    $event->error_reply("Sorry, I don't see an item like that on the agenda.");
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

  my ($owner, $agenda) = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  return $event->error_reply("Sorry, you can't strike items from that agenda.")
    unless $owner->username eq $event->from_user->username
    or $agenda->{share}{ $event->from_user->username } eq 'strike';

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

  my ($owner, $agenda) = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, you can only delete your own agendas.")
    unless $owner->username eq $event->from_user->username;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  delete $self->_useragendas->{ $event->from_user->username }{ fc $agenda->{name} };

  $self->save_state;

  return $event->reply("I deleted the agenda!");
}

my %KNOWN_PERM = map {; $_ => 1 } qw(read add strike);

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

  my ($owner, $agenda) = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, you can only share your own agendas.")
    unless $owner->username eq $event->from_user->username;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  my @instructions = map  {; [ split /:/, $_ ] }
                     grep {; length }
                     split /\s+/, $args;

  unless (@instructions) {
    return $event->error_reply("I didn't understand how you wanted to share.");
  }

  my %plan;
  my %error;

  for my $instruction (@instructions) {
    my $who  = $self->resolve_name($instruction->[0], $event->from_user);
    my $perm = $instruction->[1] // 'write';

    $error{"I don't know who `$who` is."} = 1 unless $who;

    # TTP: Totally tragic perm.
    $error{"I don't know how to share for `$perm`."} = 1
      unless $KNOWN_PERM{$perm};

    $error{"Sharing with yourself is weird and I won't allow it."} = 1
      if $who->username eq $event->from_user->username;

    $error{"You mentioned " . $who->username . " more than once!"} = 1
      if $plan{ $who->username };

    $plan{$who->username} = $perm;
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

  my ($owner, $agenda) = $self->resolve_agenda_and_user($agendaname, $event->from_user);

  return $event->error_reply("Sorry, I don't know whose agenda you want.")
    unless $owner;

  return $event->error_reply("Sorry, you can only unshare your own agendas.")
    unless $owner->username eq $event->from_user->username;

  return $event->error_reply("Sorry, I can't find that agenda.")
    unless $agenda;

  $agenda->{share} = {};

  $self->save_state;

  return $event->reply("That agenda is now entirely private.");
}

1;
