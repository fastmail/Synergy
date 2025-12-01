use v5.36.0;

use Test::Deep;
use Test::More;

use Synergy::Util qw(read_config_file);

my $toml_file = "eg/local.toml";

my $config = read_config_file($toml_file);

# Without inflate_booleans, TOML::Parser turns the boolean values into the
# strings "true" and "false" which is a bit goofy.
ok(!$config->{channels}{'term-rw'}{send_only}, "we load TOML booleans as 1/0");
ok( $config->{channels}{'term-wo'}{send_only}, "we load TOML booleans as 1/0");

done_testing;
