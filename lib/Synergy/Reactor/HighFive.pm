use v5.24.0;
package Synergy::Reactor::HighFive;

use Moose;
with 'Synergy::Role::Reactor';
with 'Synergy::Role::HTTPEndpoint';

use experimental qw(signatures);
use namespace::clean;
use Synergy::Logger '$Logger';

use JSON 2 qw(encode_json);

has '+http_path' => (
  default => '/highfive',
);

has highfive_token => (
  is  => 'ro',
  isa => 'Str',
);

has highfive_webhook => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has highfive_channel => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has highfive_dbfile => (
  is => 'ro',
  isa => 'Str',
  default => "highfives.sqlite",
);

has _highfive_dbh => (
  is  => 'ro',
  init_arg => undef,
  default  => sub ($self, @) {
    my $dbf = $self->highfive_dbfile;

    my $dbh = DBI->connect(
      "dbi:SQLite:dbname=$dbf",
      undef,
      undef,
      { RaiseError => 1 },
    );
    die $DBI::errstr unless $dbh;

    $dbh->do(q{
      CREATE TABLE IF NOT EXISTS highfives (
        id integer primary key,
        from_user TEXT not null,
        to_user TEXT not null,
        reason TEXT not null,
        highfived_at integer not null
      );
    });

    return $dbh;
  },
);

sub http_app ($self, $env) {
  unless ($self->highfive_token) {
    $Logger->log("No highfive_token configured. Ignoring highfive");
    return [ 400, [ "Content-Type" => "application/json" ], [ "{}\n" ] ];
  }

  my $req = Plack::Request->new($env);
  my $param = $req->parameters;
  unless ($param->{token} && $param->{token} eq $self->highfive_token) {
    if ($param->{token}) {
      $self->info("/highfive attempted with bad token $param->{token}");
    } else {
      $self->info("/highfive attempted with no token");
    }

    return [
      500,
      [ "Content-Type" => "application/json" ],
      [ encode_json({ error => \1 }) ],
    ];
  }

  my $who = $param->{user_name};
  my $text = Encode::decode('utf-8', $param->{text}); # XXX decode?!

  my $res;

  $self->do_highfive(
    from => $who,
    text => $text,

    # XXX: Surely not correct in direct or group chats. -- rjbs, 2018-11-14
    chan => "#$param->{channel_name}",

    success => sub {
      my ($self, $msg) = @_;
      $msg ||= '';

      $res = [
        200,
        [ 'Content-Type' => 'application/json', ],
        [ encode_json({ text => "highfive sent! $msg" }) ],
      ];
    },
    failure => sub {
      my ($self, $err) = @_;
      $err ||= '';

      $res = [
        200,
        [ 'Content-Type' => 'application/json', ],
        [ encode_json({ text => "something went wrong! $err" }) ],
      ];
    }
  );

  return $res;
};

sub listener_specs {
  return {
    name      => 'highfive',
    method    => 'highfive',
    predicate => sub ($, $e) {
      $e->was_targeted &&
      $e->text =~ /^highfive\s/i;
    },
  };
}

sub start ($self) {}

sub highfive ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->reply("Sorry, I don't know who you are.");

    return;
  }

  my $who = $event->from_user->username;
  my $chan = $event->from_channel->describe_conversation($event);

  $self->do_highfive(
    from => $who,
    text => $event->text,
    chan => $chan,
    success => sub {
      my ($self, $msg) = @_;
      $msg ||= '';

      $event->reply("Highfive sent! $msg");
    },
    failure => sub {
      my ($self, $err) = @_;
      $err ||= '';

      $event->reply("Something went wrong! $err");
    }
  );
}

sub do_highfive ($self, %arg) {
  my $from = $arg{from};
  my $text = $arg{text};
  my $chan = $arg{chan} || '';
  my $success = $arg{success} || sub {};
  my $failure = $arg{failure} || sub {};

  # "highfive to rjbs for eating pie" or "highfive for @rjbs for baking pie"
  unless ($text =~ s/\Ahighfive\s*(to|for)\s+//i) {
    $text =~ s/\Ahighfive\s*([^\s]+):?\s+/$1 /;
  }

  my ($target, $reason) = split /\s+/, $text, 2;

  my $target_user = $self->hub->user_directory->user_named($target);

  # Resolve users if possible
  $target_user = $target_user ? '@' . $target_user->username : $target;

  # "for eating pie" -> "eating pie"
  $reason =~ s/\Afor:?\s+//;

  my $response_text
    = "highfive to $target"
    . (length($reason) ? " for: $reason (via $chan)" : " (via $chan)");

  my $ok = 1;

  for my $channel (
    $self->highfive_channel,
    $target_user,
    (    $chan ne $self->highfive_channel
      && $chan !~ /^@/
        ? ( $chan ) : ()
    ),
  ) {
    my $http_res = $self->hub->http_post(
      $self->highfive_webhook,
      Content_Type => 'application/json',
      Content      => encode_json({
        text     => $response_text,
        channel  => $channel,
        username => $from,
      }),
    );

    unless ($http_res->is_success) {
      $ok = 0;

      $Logger->log([
        "Failed to contact highfive_webhook: %s",
         $http_res->as_string,
      ]);

      $failure->($self, "Failed to contact highfive_webhook for $channel");
    }
  }

  $self->_highfive_dbh->do(
    "INSERT INTO highfives
    (from_user, to_user, reason, highfived_at)
    VALUES
    (?, ?, ?, ?)",
    undef,
    $from,
    $target,
    $reason // "",
    time,
  );

  return unless $ok;

  $success->($self);

  return;
}

1;
