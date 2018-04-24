use v5.24.0;
package Synergy::Reactor::CatPic;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use Synergy::Logger '$Logger';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return (
    {
      name      => 'dog-pic',
      method    => 'handle_dog_pic',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Adog\s+pic\z/
      },
    },
    {
      name      => 'cat-pic',
      method    => 'handle_cat_pic',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /\Acat\s+(pic|jpg|gif|png)\z/
      },
    },
  );
}

sub handle_cat_pic ($self, $event, $rch) {
  $event->mark_handled;

  my (undef, $fmt) = split /\s+/, $event->text, 2;
  $fmt = q{jpg,gif,png} if $fmt eq 'pic';

  my $res = $self->hub->http->GET(
    "http://thecatapi.com/api/images/get?format=src&type=$fmt",
    max_redirects => 0,
  )->get;

  if ($res->code =~ /\A3..\z/) {
    my $loc = $res->header('Location');
    $rch->reply($loc);
    return;
  }

  $rch->reply("Something went wrong getting the kitties! \N{CRYING CAT FACE}");
  return;
}

sub handle_dog_pic ($self, $event, $rch) {
  $event->mark_handled;

  my $res = $self->hub->http->GET(
    "http://dog.ceo/api/breeds/image/random",
  )->get;

  my $json = eval { JSON::MaybeXS->new->decode( $res->decoded_content ) };
  my $error = $@;

  if ($json && $json->{status} eq 'success') {
    $rch->reply($json->{message});
    return;
  }

  $Logger->log("doggo error: $error") if $error;
  $rch->reply("Something went wrong getting the doggos!");
  return;
}

1;
