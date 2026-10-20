#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use File::Temp qw( tempdir );
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';
my $dir    = tempdir( CLEANUP => 1 ) . '/pve-purestorage';    # does not exist yet

# The state of the protection-group sync on a node (when it ran last, the lock of a run) lives with the other state
# of the plugin in one directory of the node, which the plugin creates itself.
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::purestorage_sync_array_snapshots" } = sub { return };
}
no warnings 'once';
local $PVE::Storage::Custom::PureStoragePlugin::STATUS_MARKER_DIR = $dir;

$plugin->can( 'purestorage_maybe_schedule_pgroup_sync' )->( { pgroup_sync => 1 }, 'pure' );
select( undef, undef, undef, 0.5 );
$plugin->can( 'purestorage_reap_sync_children' )->();

ok( -d $dir,                  'the directory is created' );
ok( -e "$dir/sync-pure.ts",   'the time of the last run is kept in it' );
ok( -e "$dir/sync-pure.lock", 'and the lock of the run' );
is( ( stat $dir )[2] & 07777, 0700, 'with the mode 0700' );

done_testing;
