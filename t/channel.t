#!perl
use v5.36.0;

use lib 't/lib';

use Test::More;

use Sub::Override;
use Synergy::Channel::Slack;
use Synergy::Event;
use Synergy::Tester;

package Synergy::TestReactor::Describe {
  use Moose;
  with 'Synergy::Role::Reactor::CommandPost';

  use namespace::clean;

  use Future::AsyncAwait;
  use Synergy::CommandPost;

  command describe => {} => async sub ($self, $event, $rest) {
    await $event->reply(
      sprintf 'public=%s name=%s',
        ($event->is_public ? 1 : 0),
        $event->from_channel->conversation_name($event),
    );
  };

  no Moose;
}

my $synergy = Synergy::Tester->new_tester({
  reactors => {
    describe => { class => 'Synergy::TestReactor::Describe' },
  },
  default_from => 'alice',
  users => {
    alice => undef,
  },
});

my sub describe_event ($arg) {
  my $channel = $synergy->channel_named('test-channel');
  $channel->clear_messages;

  $synergy->run_test_program([
    [ send => { text => 'synergy: describe', $arg->%* } ],
  ]);

  my @sent = $channel->sent_messages;
  return $sent[0]{text};
}

subtest 'injected events are private by default' => sub {
  like(
    describe_event({}),
    qr{\bpublic=0\b},
    "an injected event is private unless asked otherwise",
  );
};

subtest 'injected events can be public' => sub {
  # A public reply is prefixed with the speaker's username, so match loosely.
  like(
    describe_event({ public => 1 }),
    qr{\bpublic=1\b},
    "public => 1 produces a public event",
  );
};

subtest 'the conversation address can be set' => sub {
  like(
    describe_event({ conversation_address => 'bikeshed' }),
    qr{\bname=bikeshed\b},
    "conversation_address is used, and names the conversation",
  );

  like(
    describe_event({}),
    qr{\bname=public\b},
    "it still defaults to 'public'",
  );
};

subtest 'Slack names conversations by channel name' => sub {
  my $slack_channel = Synergy::Channel::Slack->new({
    name    => 'slack-test',
    api_key => 'bogus-api-key',
  });

  my sub event_in ($address) {
    return Synergy::Event->new({
      type                 => 'message',
      text                 => 'hello',
      from_address         => 'alice',
      from_channel         => $slack_channel,
      conversation_address => $address,
    });
  }

  is(
    $slack_channel->conversation_name(event_in('C0BIKESHED')),
    'C0BIKESHED',
    "before the channel is ready, the address is returned as-is",
  );

  my $override = Sub::Override->new;
  $override->replace('Synergy::Channel::Slack::slack' => sub {
    return bless { channels => { C0BIKESHED => { name => 'bikeshed' } } },
      'Synergy::TestSlackClient';
  });

  $slack_channel->readiness->done;

  is(
    $slack_channel->conversation_name(event_in('C0BIKESHED')),
    'bikeshed',
    "a known channel id becomes its name",
  );

  is(
    $slack_channel->conversation_name(event_in('D0MONOLOG')),
    'D0MONOLOG',
    "an unknown address (like a DM) is returned as-is",
  );
};

package Synergy::TestSlackClient {
  sub channels ($self) { return $self->{channels} }
}

done_testing;
