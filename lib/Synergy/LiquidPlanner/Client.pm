use v5.28.0;
use warnings;
package Synergy::LiquidPlanner::Client;

use Moose;

use experimental qw(signatures lexical_subs);
use namespace::clean;
use JSON::MaybeXS ();
use DateTime;
use utf8;
use URI::Find;

my $JSON = JSON::MaybeXS->new->utf8;

has workspace_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has auth_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has logger_callback => (
  required => 1,
  traits   => [ 'Code' ],
  required => 1,
  handles  => { 'logger' => 'execute_method' },
);

sub log       { (shift)->logger->log(@_) }
sub log_debug { (shift)->logger->log_debug(@_) }

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
}

# Yes, this means that even though an undef payload is technically possible, we
# turn it into a nil result.  If you really need a non-nil undef, construct one
# by hand.  But you probably don't. -- rjbs, 2018-06-26
my sub _failure { state $fail = LPC::Result::Failure->new; return $fail }
my sub _success ($payload) {
  return (defined $payload) ? LPC::Result::Success->new({ payload => $_[0] })
                            : LPC::Result::Success->new;
}

sub _http_failure ($self, $http_res, $desc = undef) {
  my $req = $http_res->request;
  my $details = $req ? sprintf(' (%s %s)', $req->method, $req->uri) : q{};

  $self->log([
    "error with %s%s: %s",
    $desc // "HTTP operation",
    $details,
    $http_res->as_string,
  ]);
  return _failure;
}

has http_get_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  traits => [ 'Code' ],
  required => 1,
  handles  => { 'http_get_raw' => 'execute_method' },
);

has http_post_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  traits => [ 'Code' ],
  required => 1,
  handles  => { 'http_post_raw' => 'execute_method' },
);

has http_put_callback => (
  is  => 'ro',
  isa => 'CodeRef',
  traits => [ 'Code' ],
  required => 1,
  handles  => { 'http_put_raw' => 'execute_method' },
);

sub http_get ($self, $path, @arg) {
  my $uri = $self->_lp_base_uri . $path;

  my $http_res = $self->http_get_raw(
    $uri,
    @arg,
    Authorization => $self->auth_token,
  );

  return $self->_http_failure($http_res) unless $http_res->is_success;

  my $payload = $JSON->decode($http_res->decoded_content);
  return _success($payload);
}

sub http_post ($self, $path, @arg) {
  my $uri = $self->_lp_base_uri . $path;

  my $http_res = $self->http_post_raw(
    $uri,
    @arg,
    Authorization => $self->auth_token,
  );

  return $self->_http_failure($http_res) unless $http_res->is_success;

  my $payload = $JSON->decode($http_res->decoded_content);
  return _success($payload);
}

sub get_clients ($self) {
  my $lp_res = $self->http_get("/clients");

  return $lp_res unless $lp_res->is_success;
  return _success($lp_res->payload);
}

sub get_item ($self, $item_id) {
  my $lp_res = $self->http_get(
    "/treeitems/"
    . "?filter[]=id=$item_id"
    . "&include=comments,links,tags"
  );

  return $lp_res unless $lp_res->is_success;
  return _success($lp_res->payload->[0]);
}

has single_activity_id => (
  is  => 'ro',
  isa => 'Int',
  predicate => 'has_single_activity_id',
);

sub get_activity_id ($self, $task_or_id, $member_id = undef) {
  return _success($self->single_activity_id) if $self->has_single_activity_id;
  return _failure("get_activity_id not really implemented");
}

sub my_timers ($self) {
  return $self->http_get("/my_timers");
}

sub my_running_timer ($self) {
  # Treat as impossible, for now, >1 running timer. -- rjbs, 2018-06-26
  my $timer_res = $self->my_timers;
  return $timer_res unless $timer_res->is_success;

  my ($timer) = grep {; $_->{running} } $timer_res->payload_list;
  if ($timer) {
    $timer = LPC::Timer->new($timer);
  }
  return _success($timer);
}

sub query_items ($self, $arg) {
  my $query = URI->new("/treeitems" . ($arg->{in} ? "/$arg->{in}" : q{}));

  $query->query_param(include => 'comments,links,tags');
  for my $flag (keys $arg->{flags}->%*) {
    $query->query_param($flag => $arg->{flags}{$flag});
  }

  for my $filter ($arg->{filters}->@*) {
    my $string = join q{ }, @$filter;
    $query->query_param_append('filter[]' => $string);
  }

  return $self->http_get("$query");
}

sub upcoming_task_groups_for_member_id ($self, $member_id, $limit = 200) {
  return $self->http_get(
    "/upcoming_tasks?limit=$limit&member_id=$member_id",
  );
}

sub start_timer_for_task_id ($self, $task_id) {
  my $start_res = $self->http_post("/tasks/$task_id/timer/start");
  return $start_res unless $start_res->is_success;
  return _failure unless $start_res->payload->{running}; # Really??
  return $start_res;
}

sub stop_timer_for_task_id ($self, $task_id) {
  return $self->http_post("/tasks/$task_id/timer/stop");
}

sub clear_timer_for_task_id ($self, $task_id) {
  return $self->http_post("/tasks/$task_id/timer/clear");
}

sub track_time ($self, $arg) {
  Carp::confess("no task_id")     unless $arg->{task_id};
  Carp::confess("no activity_id") unless $arg->{activity_id};
  Carp::confess("no work")        unless defined $arg->{work};
  Carp::confess("no member_id")   unless $arg->{member_id};

  my $comment = $arg->{comment};

  if (defined $comment) {
    # Linkify URL-looking things
    my $finder = URI::Find->new(sub ($uri, $orig_text) {
      return qq{<a href="$orig_text">$orig_text</a>};
    });

    $finder->find(\$comment);
  }

  my $res = $self->http_post(
    "/tasks/$arg->{task_id}/track_time",
    Content_Type => 'application/json',
    Content => $JSON->encode({
      activity_id => $arg->{activity_id},
      member_id => $arg->{member_id},
      work      => $arg->{work},
      reduce_estimate => \1,

      (defined $comment ? (comment => $comment) : ()),
    }),
  );

  return $res unless $res->is_success;

  my $task = $res->payload;

  my ($assignment) = grep {; $_->{person_id} == $arg->{member_id} }
                     $task->{assignments}->@*;

  die "WHERE IS MY ASSIGNMENT" unless $assignment;

  if ($arg->{done} xor $assignment->{is_done}) {
    my $assignment_res = $self->http_post(
      "/tasks/$arg->{task_id}/update_assignment",
      Content_Type => 'application/json',
      Content => $JSON->encode({
        assignment_id => $assignment->{id},
        is_done       => ($arg->{done} ? \1 : \0),
      }),
    );

    return $assignment_res unless $assignment_res->is_success;
  }

  return _success({
    item_id => $arg->{task_id},
    work    => $arg->{work},
    assignment_id => $assignment->{id},
  });
}

sub create_task ($self, $task) {
  return $self->http_post(
    "/tasks",
    Content_Type => 'application/json',
    Content => $JSON->encode($task),
  );
}

# get current iteration data
sub tags ($self) {
  return $self->http_get("/tags");
}

sub todo_items ($self) {
  return $self->http_get("/todo_items");
}

sub create_todo_item ($self, $todo) {
  return $self->http_post(
    "/todo_items",
    Content_Type => 'application/json',
    Content => $JSON->encode({ todo_item => $todo }),
  );
}

sub current_iteration ($self) {
  my $helper = LPC::IterationHelper->new({ lpc => $self });

  my $iter    = $helper->current_iteration;
  my $pkg_res = $helper->package_for_iteration_number($iter->{number});

  return unless $pkg_res->is_success;

  return {
    %$iter,
    package => $pkg_res->payload,
  };
}

sub iteration_by_number ($self, $n) {
  my $helper = LPC::IterationHelper->new({ lpc => $self });

  my $iter    = $helper->iteration_by_number($n);
  my $pkg_res = $helper->package_for_iteration_number($iter->{number});

  return unless $pkg_res->is_success;

  return {
    %$iter,
    package => $pkg_res->payload,
  };
}

sub iteration_relative_to_current ($self, $delta_n) {
  my $helper = LPC::IterationHelper->new({ lpc => $self });

  my $iter    = $helper->iteration_relative_to_current($delta_n);
  my $pkg_res = $helper->package_for_iteration_number($iter->{number});

  return unless $pkg_res->is_success;

  return {
    %$iter,
    package => $pkg_res->payload,
  };
}

package LPC::Timer {
  use Moose;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);
  use Time::Duration;

  for my $prop (qw(
    total_time
    person_id
    running
    id
    item_id
    type
    running_time
  )) {
    has $prop => (is => 'ro');
  }

  # Total time is a *lie*. It's undef if the timer has never
  # been stopped/resumed. If it has been resumed, it's only
  # the previous time, not including current running time...
  sub real_total_time ($self) {
    return ($self->total_time // 0) + $self->running_time;
  }

  for my $prop (qw(
    real_total_time
    total_time
    running_time
  )) {
    no strict 'refs';

    my $sub = $prop . "_duration";

    *$sub = sub ($self) {
      return concise( duration( $self->$prop * 3600 ) );
    };
  }
}

package LPC::Result::Success {
  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);

  sub is_success { 1 };

  has payload => (is => 'ro', predicate => 'has_payload');

  sub is_nil ($self) { ! $self->has_payload }

  sub payload_list ($self) {
    return () if $self->is_nil;

    my $payload = $self->payload;
    Carp::confess("payload_list with non-arrayref payload")
      unless ref $payload and ref $payload eq 'ARRAY';

    return @$payload;
  }

  __PACKAGE__->meta->make_immutable;
}

package LPC::Result::Failure {
  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);

  sub is_success { 0 };
  sub is_nil     { 0 };

  sub payload       { Carp::confess("tried to interpret failure as success") }
  sub payload_list  { Carp::confess("tried to interpret failure as success") }

  __PACKAGE__->meta->make_immutable;
}

package LPC::IterationHelper {
  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);

  has lpc => (is => 'ro', required => 1, weak_ref => 1);

  # This is stupid hard-coding, but it eliminates much, much stupider
  # hard-coding. -- rjbs, 2019-02-27
  my @Sync_Points = (
    [ '2016-12-31' => '200' ],
    [ '2017-12-24' => '224' ],
  );

  sub iteration_by_number ($self, $n) {
    my @candidates = grep {; $_->[1] <= $n } @Sync_Points;
    die "can't compute iteration #$n" unless @candidates;

    my ($sync_start, $sync_number) = @{ $candidates[-1] };

    my (@ymd) = split /-/, $sync_start;
    my $sync_start_dt = DateTime->new(
      year  => $ymd[0],
      month => $ymd[1],
      day   => $ymd[2],
    );

    my $iters = $n - $sync_number;

    my $i_start = $sync_start_dt + DateTime::Duration->new(days => $iters * 14);
    my $i_end   = $i_start       + DateTime::Duration->new(days => 13);

    return {
      number => $n,
      start  => $i_start->ymd,
      end    => $i_end->ymd,
    };
  }

  sub iteration_on_date ($self, $datetime) {
    if (! ref $datetime) {
      state $strp = DateTime::Format::Strptime->new(pattern => '%F');
      my $obj = $strp->parse_datetime($datetime);
      die qq{can't understand date string "$datetime"} unless $obj;
      $datetime = $obj;
    }

    my $ymd = $datetime->ymd('-');
    my @candidates = grep {; $_->[0] le $ymd } @Sync_Points;
    die "can't compute iteration for $ymd" unless @candidates;

    my ($sync_start, $sync_number) = @{ $candidates[-1] };

    my (@ymd) = split /-/, $sync_start;
    my $sync_start_dt = DateTime->new(
      year  => $ymd[0],
      month => $ymd[1],
      day   => $ymd[2],
    );

    my $days = int($datetime->jd) - int($sync_start_dt->jd);
    my $fns = int $days / 14;

    my $i_start = $sync_start_dt + DateTime::Duration->new(days => $fns * 14);
    my $i_end   = $i_start       + DateTime::Duration->new(days => 13);

    return {
      number => $sync_number + $fns,
      start  => $i_start->ymd,
      end    => $i_end->ymd,
    };
  }

  sub current_iteration ($self) {
    my $iter = $self->iteration_on_date(DateTime->now);
    return $iter;
  }

  sub iteration_relative_to_current ($self, $delta_n) {
    return $self->iteration_on_date(
      DateTime->now->add(weeks => 2 * $delta_n)
    );
  }

  sub package_for_iteration_number ($self, $n) {
    # We could cache this, but the lifecycle of IterationHelper and LPC objects
    # is not really reliable and we'd end up with duplicates and it would be
    # stupid. -- rjbs, 2019-02-27
    my $res = $self->lpc->query_items({
      # in => $root_id
      flags => {
        depth => -1,
        flat  => 1,
      },
      filters => [
        [ name   => 'starts_with',  "#$n" ],
      ],
    });

    return $res unless $res->is_success;

    return _success($res->payload->[0]);
  }

  sub package_for_current_iteration ($self) {
    state $iter = $self->iteration_on_date(DateTime->now);
    return $self->package_for_iteration_number($iter->{number});
  }
}

1;
