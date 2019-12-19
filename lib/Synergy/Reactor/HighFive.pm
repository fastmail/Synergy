use v5.24.0;
use warnings;
use utf8;
package Synergy::Reactor::HighFive;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';
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

has to_channel => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has to_address => (
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
  lazy     => 1,
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

my $HIGHFIVE_EMOJI = "\N{PERSON RAISING BOTH HANDS IN CELEBRATION}";

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

  my $synthetic_message = $self->hub->name . q{: } . $text;

  my $channel = $self->hub->channel_named($self->to_channel);

  my $event = $channel->synergy_event_from_slack_event({
    channel => $param->{channel_id},
    user    => $param->{user_id},
    type    => 'message',
    text    => $text,

    # we'll want to keep something like this when we make a Slack::WebHook
    # channel?
    webhook_params => $param,
  });

  my $ok;
  $self->highfive($event, { ok_ref => \$ok });

  return [
    200,
    [ 'Content-Type' => 'application/json', ],
    [ encode_json({ text => $ok ? "Highfive sent!" : "Something went wrong!" }) ],
  ];
}

sub listener_specs {
  return {
    name      => 'highfive',
    method    => 'highfive',
    predicate => sub ($, $e) {
      $e->was_targeted &&
      $e->text =~ /^(highfive|:raised_hands:(?::skin-tone-\d:)?|$HIGHFIVE_EMOJI)\s/in;
    },
  };
}

sub start ($self) {}

sub highfive ($self, $event, $arg = {}) {
  $event->mark_handled;

  my $ok_ref = $arg->{ok_ref};

  unless ($event->from_user) {
    if ($ok_ref)  { $$ok_ref = 0; }
    else          { $event->reply("Sorry, I don't know who you are."); }

    return;
  }

  my $who = $event->from_user->username;

  $self->do_highfive(
    $event,

    from => $who,
    text => $event->text,
    chan => $event->conversation_address,
    chandesc => $event->from_channel->describe_conversation($event),
    success => sub {
      my ($self, $msg) = @_;
      $msg ||= '';

      if ($ok_ref) { $$ok_ref = 1 }
      else         { $event->reply("Highfive sent! $msg"); }
    },
    failure => sub {
      my ($self, $err) = @_;
      $err ||= '';

      if ($ok_ref) { $$ok_ref = 0 }
      else         { $event->reply("Something went wrong! $err"); }
    }
  );
}

sub do_highfive ($self, $event, %arg) {
  my $from = $arg{from};
  my $text = $arg{text};
  my $chan = $arg{chan} || '';
  my $chandesc = $arg{chandesc} || '';
  my $success = $arg{success} || sub {};
  my $failure = $arg{failure} || sub {};

  # This skin tone won't work yet for real emoji, but this is ok for slack.
  # -- michael, 2019-12-19
  my $prefix = qr{(?:highfive|:raised_hands:(?::skin-tone-\d:)?|\Q$HIGHFIVE_EMOJI\E)}i;

  # "highfive to rjbs for eating pie" or "highfive for @rjbs for baking pie"
  unless ($text =~ s/\A$prefix\s*(to|for)\s+//i) {
    $text =~ s/\A$prefix\s*([^\s]+):?\s+/$1 /;
  }

  my ($target, $reason) = split /\s+/, $text, 2;

  # @user -> user or user_named won't resolve
  $target =~ s/^@//;

  my $target_user = $self->hub->user_directory->user_named($target);

  # This is the per-channel user id (like the Slack userid) of the targeted
  # user on the channel on which we send our high fives messages.
  my $target_user_id = $target_user
                  && $target_user->identity_for($self->to_channel);

  # "for eating pie" -> "eating pie"
  $reason =~ s/\Afor:?\s+//;

  my $response_text
    = "highfive to $target"
    . (length($reason) ? " for: $reason (via $chandesc)" : " (via $chandesc)");

  my $ok = 1;
  for my $channel (
    $self->to_address,
    ($target_user_id ? $target_user_id : ()),
    (($chan && $chan ne $self->to_address) ? $chan : ()),
  ) {
    $Logger->log("sending highfive notice to $channel");

    if ($channel =~ /^[DG]/) {
      $event->reply($response_text);
    } else {
      my $http_res = $self->hub->http_post(
        $self->highfive_webhook,
        Content_Type => 'application/json',
        Content      => encode_json({
          text      => $response_text,
          channel   => $channel,
          username  => $from,
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
