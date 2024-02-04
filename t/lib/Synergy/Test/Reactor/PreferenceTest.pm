use v5.32.0;
package Synergy::Test::Reactor::PreferenceTest;

use utf8;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::HasPreferences';

use experimental 'signatures';

use Future::AsyncAwait;
use Synergy::Util qw(bool_from_text);

# We will never react.
sub potential_reactions_to {}

__PACKAGE__->add_preference(
  name      => 'bool-pref',
  validator => async sub ($self, $value, @) { return bool_from_text($value) },
  default   => 0,
  description => 'a boolean preference',
);

1;
