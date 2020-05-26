use v5.24.0;
use warnings;
package Synergy::Reactor::HelpSpot;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use URI;
use URI::QueryParam;
use XML::LibXML;

use experimental qw(signatures);
use namespace::clean;
use utf8;

sub listener_specs {
  return;
}

after register_with_hub => sub ($self, @) {
  $self->fetch_state;   # load prefs
};

has auth_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has api_uri => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

sub _http_get ($self, $param) {
  my $uri = URI->new($self->api_uri);

  $uri->query_form_hash($param);

  my $res = $self->hub->http_get(
    $uri,
    Authorization => 'Basic ' . $self->auth_token,
    'User-Agent'  => __PACKAGE__,
  );
}

sub ticket_report ($self, $who, $arg = {}) {
  return unless my $user_id = $self->get_user_preference($who, 'user-id');

  $self->_http_get({
    method => 'private.request.search',
    fOpen  => 1,
    xPersonAssignedTo => $user_id,
  })->then(sub ($res) {
    open my $fh, '<', \$res->decoded_content(charset => 'none')
      or die "error making handle to XML results: $!";

    my $doc = XML::LibXML->load_xml(IO => $fh);

    # HelpSpot is ludicrous.  If there are 0 requests, you get...
    # <requests>
    #   <request />
    # </requests>
    # ...instead of just a zero-child <requests>.  What the heck?
    # -- rjbs, 2019-03-26
    my $count = grep {; $_->getChildrenByTagName('xRequest') }
                $doc->getElementsByTagName('request');

    return Future->done unless $count;

    my $desc = $arg->{description} // "HelpSpot tickets";
    my $text = sprintf "\N{ADMISSION TICKETS} %s: %s", $desc, $count;

    return Future->done([ $text, { slack => $text } ]);
  });
}

sub unassigned_report ($self, $who, $arg = {}) {
  $self->_http_get({
    method => 'private.request.search',
    ($arg->{search_args} ? $arg->{search_args}->%* : ()),
  })->then(sub ($res) {
    open my $fh, '<', \$res->decoded_content(charset => 'none')
      or die "error making handle to XML results: $!";

    my $doc = XML::LibXML->load_xml(IO => $fh);

    my @requests = $doc->getElementsByTagName('request');

    my $count = 0;
    for my $request (@requests) {
      my ($person) = $request->getElementsByTagName('xPersonAssignedTo');
      next if $person && $person->textContent;
      $count++;
    }

    return Future->done unless $count;

    my $desc = $arg->{description} // "tickets";
    return Future->done([
      "\N{BUG} Unassigned $desc: $count",
      { slack => "\N{BUG} Unassigned $desc: $count" },
    ]);
  });
}

sub _filter_count_report ($self, $who, $arg) {
  $self->_http_get({
    method => 'private.filter.get',
    xFilter  => $arg->{filter_id},
  })->then(sub ($res) {

    open my $fh, '<', \$res->decoded_content(charset => 'none')
      or die "error making handle to XML results: $!";

    my $doc = XML::LibXML->load_xml(IO => $fh);

    my $count = grep {; $_->getChildrenByTagName('xRequest') }
                $doc->getElementsByTagName('request');

    return Future->done unless $count;

    my $desc  = $arg->{description};
    my $emoji = $arg->{emoji};
    my $text = sprintf "$emoji %s: %s", $desc, $count;

    return Future->done([ $text, { slack => $text } ]);
  });
}

sub urgent_report ($self, $who, $arg = {}) {
  $arg->{description} //= "All Urgent";
  $arg->{emoji}       //= "\N{HEAVY EXCLAMATION MARK SYMBOL}";
  return $self->_filter_count_report($who, $arg);
}

sub inbox_unassigned_report ($self, $who, $arg = {}) {
  $arg->{description} //= "Inbox, Unassigned";
  $arg->{emoji}       //= "\N{OPEN MAILBOX WITH RAISED FLAG}";
  return $self->_filter_count_report($who, $arg);
}

sub inbox_report ($self, $who, $arg = {}) {
  $arg->{description} //= "Inbox, Total";
  $arg->{emoji}       //= "\N{OPEN MAILBOX WITH LOWERED FLAG}";
  return $self->_filter_count_report($who, $arg);
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  validator => sub ($self, $value, @) {
    return $value if $value =~ /\A[0-9]+\z/;
    return (undef, "Your user-id must be a positive integer.")
  },
  default   => undef,
);

1;
