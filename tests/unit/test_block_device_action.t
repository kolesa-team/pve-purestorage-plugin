#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use File::Path qw( make_path );
use File::Temp qw( tempdir );
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';
my $action = $plugin->can( 'block_device_action' ) // BAIL_OUT( "$plugin has no block_device_action" );

# The kernel takes a path offline and deletes it through files under /sys/block/<disk>/device. The two steps
# are separate actions so that the volume can be disconnected on the array between them.
my $sysfs = tempdir( CLEANUP => 1 );
make_path( "$sysfs/sdg/device" );

sub reset_files {
  for my $file ( qw( state delete rescan ) ) {
    open( my $fh, '>', "$sysfs/sdg/device/$file" ) or die $!;
    close $fh;
  }
}
sub text { open( my $fh, '<', $_[0] ) or return undef; local $/; return scalar <$fh> }

my @commands;
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::exec_command" } = sub { push @commands, join( ' ', @{ $_[0] } ); return 1 };
}
no warnings 'once';
local $PVE::Storage::Custom::PureStoragePlugin::SYSFS_BLOCK = $sysfs;

reset_files();
$action->( 'offline', 'sdg' );
is( text( "$sysfs/sdg/device/state" ),  "offline\n", 'offline writes "offline" and a newline to the state file (the kernel refuses it without the newline)' );
is( text( "$sysfs/sdg/device/delete" ), '',          'offline does not delete the device' );
ok( ( grep { /blockdev --flushbufs \/dev\/sdg/ } @commands ), 'the buffers are flushed before the path goes offline' );

reset_files();
$action->( 'delete', 'sdg' );
is( text( "$sysfs/sdg/device/delete" ), "1\n", 'delete writes "1" to the delete file' );

reset_files();
$action->( 'rescan', 'sdg' );
is( text( "$sysfs/sdg/device/rescan" ), "1\n", 'rescan writes "1" to the rescan file' );

ok( !eval { $action->( 'frobnicate', 'sdg' ); 1 }, 'an unknown action is an error' );

# A write the kernel refuses (/dev/full answers every write with an error) is logged, not silent and not fatal:
# the cleanup of the other paths goes on.
SKIP: {
  skip '/dev/full is not available', 1 unless -e '/dev/full';
  reset_files();
  unlink "$sysfs/sdg/device/state";
  symlink '/dev/full', "$sysfs/sdg/device/state" or die $!;
  ok( eval { $action->( 'offline', 'sdg' ); 1 }, 'a refused write does not stop the cleanup' ) or diag( $@ );
}

# A path that vanished (its sysfs directory is gone) or whose buffers cannot be flushed does not stop the cleanup of
# the paths after it: they are taken offline and deleted all the same.
make_path( "$sysfs/sdh/device" );
for my $disk ( qw( sdg sdh ) ) {
  for my $file ( qw( state delete ) ) {
    open( my $fh, '>', "$sysfs/$disk/device/$file" ) or die $!;
    close $fh;
  }
}
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::exec_command" } = sub { die "flush failed\n" if $_[1] // 1; return 1 };
}
rmdir( "$sysfs/sdg/device" ) or system( 'rm', '-rf', "$sysfs/sdg/device" );
ok( eval { $action->( 'offline', 'sdg', 'sdh' ); 1 }, 'a vanished path and a failed flush do not stop the offline step' ) or diag( $@ );
is( text( "$sysfs/sdh/device/state" ), "offline\n", 'the path after the vanished one went offline' );
ok( eval { $action->( 'delete', 'sdg', 'sdh' ); 1 }, 'a vanished path does not stop the delete step' ) or diag( $@ );
is( text( "$sysfs/sdh/device/delete" ), "1\n", 'the path after the vanished one was deleted' );

done_testing;
