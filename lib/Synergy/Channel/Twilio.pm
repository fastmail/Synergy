use v5.24.0;
package Synergy::Channel::Twilio;

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS qw(encode_json decode_json);

use Synergy::Event;
use Synergy::ReplyChannel;

use namespace::autoclean;

with 'Synergy::Role::Channel';

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub start ($self) {
  $self->hub->server->register_path('/sms', sub ($req) {
    return [200, [], [ 'great!' ]];
  });
}


sub send_text ($self, $target, $text) {
  return;
}

1;
