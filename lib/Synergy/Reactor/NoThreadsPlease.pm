use v5.28.0;
use warnings;
package Synergy::Reactor::NoThreadsPlease;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures);
use namespace::clean;

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

sub listener_specs {
  return {
    name      => 'no_threads_please',
    method    => 'handle_thread',
    exclusive => 0,
    predicate => sub ($self, $e) {
      return unless $e->from_channel->isa('Synergy::Channel::Slack');
      my $td = $e->transport_data;
      return unless $td->{thread_ts} && $td->{thread_ts} ne $td->{ts};
      return 1;
    },
    allow_empty_help => 1,
  };
}

has message_text => (
  is      => 'ro',
  default => "On this Slack, the use of threads is discouraged.",
);

has recent_threads => (
  is  => 'ro',
  default   => sub {  []  },
  init_arg => undef,
);

sub handle_thread ($self, $event) {
  my $time_ago = time - 1800;
  $self->recent_threads->@* = grep {; $_->{at} >= $time_ago }
                              $self->recent_threads->@*;

  my $transport_data = $event->transport_data;

  return if $self->is_allowed_channel($transport_data->{channel});

  return if grep {; $_->{thread} eq $transport_data->{thread_ts} }
            $self->recent_threads->@*;

  push $self->recent_threads->@*, {
    at     => time,
    thread => $transport_data->{thread_ts},
  };

  $event->reply(
    "This string is unreachable.",
    {
      slack => {
        text      => $self->message_text,
        thread_ts => $transport_data->{thread_ts},
      },
    },
  );

  return;
}

1;
