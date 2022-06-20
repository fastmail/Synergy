use v5.28.0;
use warnings;

# NOTE: This sucks, because the semantics of Future::Exception suck. You can
# throw them, but that's only useful if you catch {} them, which we never do
# because that requires using the other try module (Syntax::Keyword::Try, or
# native try/catch post-5.34). You also can't really say return
# Synerge::Exception->new(...)->as_future, because then you don't even get
# back the exception object as an argument to your thing.
#
# What I actually want is to be able to write:
#
# do_a_thing()
# ->then(sub { success case... })
# ->else(sub ($err) {
#   if ($err isa 'Synergy::Exception::Whatever') {
#     handle_known_case_one;
#   } elsif ($err isa 'Synergy::Exception::Banana') {
#     eat_banana()
#   } else {
#     return 'totally weird error';
#   }
# })
#
# But such a thing does not seem easily possible, because Future.pm doesn't
# have the notion of Failure objects, only Futures which are failed, and you
# can only really fail with ($message, $category, @details), and
# fail($exception) feels like it's swimming upstream.

package Synergy::Exception {
  use experimental 'signatures';

  sub new ($class, $type, $message, @details) {
    my $subclass = "Synergy::Exception::$type";
    return $subclass->new($message, @details);
  }
}

package Synergy::Exception::Base {
  use parent 'Future::Exception';
  use experimental 'signatures';

  sub new ($class, $message, @details) {
    my $category = $class =~ s/^Synergy::Exception:://r;
    my $self = $class->SUPER::new($message, $category, @details);
    return $self;
  }
}

package Synergy::Exception::PreferenceValidation {
  use parent -norequire, 'Synergy::Exception::Base';
}

package Synergy::Exception::PreferenceDescription {
  use parent -norequire, 'Synergy::Exception::Base';
}

1;
