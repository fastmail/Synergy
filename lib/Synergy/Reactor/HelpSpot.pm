use v5.24.0;
use warnings;
package Synergy::Reactor::HelpSpot;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::HasPreferences';

use URI;
use URI::QueryParam;
use XML::LibXML;

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return;
}

sub state ($self) {
  return {
    preferences => $self->user_preferences,
  };
}

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }
  }
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
    async => 1,
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
  return if $arg->{triage_only} && ! $who->is_on_triage;

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

__PACKAGE__->add_preference(
  name      => 'user-id',
  validator => sub ($self, $value, @) {
    return $value if $value =~ /\A[0-9]+\z/;
    return (undef, "Your user-id must be a positive integer.")
  },
  default   => undef,
);

1;
