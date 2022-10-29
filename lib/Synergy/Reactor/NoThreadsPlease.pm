use v5.34.0;
use warnings;
package Synergy::Reactor::NoThreadsPlease;

use Moose;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

has allow_channels => (
  is => 'ro',
  isa =>  'ArrayRef' ,
  default => sub { [] },
);

has _channels_allowed => (
  is => 'ro',
  isa =>  'HashRef' ,
  traits => ['Hash'],
  lazy => 1,
  default => sub { +{ map {; $_ => 1 } $_[0]->allow_channels->@* } },
  handles => {
    is_allowed_channel => 'get',
  }
);

has message_text => (
  is      => 'ro',
  default => "On this Slack, the use of threads is discouraged.",
);

has recent_threads => (
  is  => 'ro',
  default   => sub {  []  },
  init_arg => undef,
);

listener no_threads_please => async sub ($self, $event) {
  return unless $event->from_channel->isa('Synergy::Channel::Slack');

  my $transport_data = $event->transport_data;

  return unless $transport_data->{thread_ts}
             && $transport_data->{thread_ts} ne $transport_data->{ts};

  my $time_ago = time - 1800;
  $self->recent_threads->@* = grep {; $_->{at} >= $time_ago }
                              $self->recent_threads->@*;

  return if $self->is_allowed_channel($transport_data->{channel});

  return if grep {; $_->{thread} eq $transport_data->{thread_ts} }
            $self->recent_threads->@*;

  push $self->recent_threads->@*, {
    at     => time,
    thread => $transport_data->{thread_ts},
  };

  await $event->reply(
    "This string is unreachable.",
    {
      slack => {
        text      => $self->message_text,
        thread_ts => $transport_data->{thread_ts},
      },
    },
  );
};

1;
