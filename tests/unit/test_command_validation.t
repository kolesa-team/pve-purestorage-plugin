#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use File::Basename qw( basename );
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $get    = $plugin->can( 'get_command_path' ) // BAIL_OUT( "$plugin has no get_command_path" );
my $check  = $plugin->can( 'check_commands' )   // BAIL_OUT( "$plugin has no check_commands" );

# The command paths are fixed in the plugin (/sbin/multipath ...), so which of them exist depends on the
# machine; each case holds both where the tool is installed and where it is not.
my @names = qw( multipath multipathd blockdev dmsetup kpartx udevadm sync );

eval { $get->( 'unknown_command' ) };
like( $@, qr/Unknown command 'unknown_command'/, 'unknown command dies' );

my $missing = 0;
for my $name ( @names ) {
  my $path = eval { $get->( $name ) };
  if ( defined $path ) {
    ok( -x $path && basename( $path ) eq $name, "$name resolves to the executable $path" );
  } else {
    $missing++;
    like( $@, qr{^Command '\Q$name\E' not found or not executable at '(?:[^']*/)?\Q$name\E'}, "$name that is not installed dies with its path" );
  }
}

is( ( $check->() ? 1 : 0 ), ( $missing ? 0 : 1 ), 'check_commands is true exactly when every command resolves' );

done_testing;
