use v5.24.0;
package Synergy::Reactor::CatPic;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

sub listener_specs {
  return {
    name      => 'cat-pic',
    method    => 'handle_cat_pic',
    exclusive => 1,
    predicate => sub ($self, $e) {
      $e->was_targeted && $e->text =~ /\Acat\s+(pic|jpg|gif|png)\z/
    },
  };
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

1;
