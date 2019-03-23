use v5.24.0;
use warnings;
package Synergy::Reactor::HelpSpot;

use Moose;
with 'Synergy::Role::Reactor';

use URI;
use URI::QueryParam;
use XML::LibXML;

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return;
}

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

sub helpspot_report ($self, $who) {
  return Future->done([ "not yet implemented" ]);
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

1;
