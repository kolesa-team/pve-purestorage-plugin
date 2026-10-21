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
$plugin->can( 'purestorage_unmap_volume' ) // BAIL_OUT( "$plugin has no purestorage_unmap_volume" );

# iscsid rescans the sessions regularly and brings a removed path back while the volume is still connected on
# the array; the path then fails once the array disconnects the volume. So every path goes offline first, the
# array disconnects the volume, and only then the paths are deleted.
my @events;
my @paths;
my $sysfs      = tempdir( CLEANUP => 1 );
my $keep_paths = 0;                         # 1: the kernel does not drop the paths when they are deleted
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::purestorage_get_wwn" }        = sub { return ( '', '3624a93708476f68c18374e7700016a84' ) };
  *{ "${pkg}::block_device_paths_by_wwid" } = sub { return @paths };
  *{ "${pkg}::multipath_check" }            = sub { push @events, 'multipath_check'; return 1 };
  *{ "${pkg}::exec_command" }               = sub { push @events, join( ' ', @{ $_[0] } ); return 1 };
  *{ "${pkg}::exec_quiet" }                 = sub { push @events, join( ' ', @{ $_[0] } ); return 1 };
  *{ "${pkg}::block_device_action" }        = sub {
    my ( $action, @devices ) = @_;
    push @events, "$action @devices";
    rmdir "$sysfs/$_" for $action eq 'delete' && !$keep_paths ? @devices : ();
  };
  *{ "${pkg}::purestorage_volume_connection" } = sub { push @events, 'array disconnect' };
}

no warnings 'once';
local $PVE::Storage::Custom::PureStoragePlugin::SYSFS_BLOCK          = $sysfs;
local $PVE::Storage::Custom::PureStoragePlugin::PATH_REMOVAL_TIMEOUT = 1;

sub run_deactivate {
  ( @paths, @events ) = ( @_, () );
  make_path( map { "$sysfs/$_" } @paths );
  $plugin->deactivate_volume( 'pure', {}, 'vm-100-disk-0' );
  return grep { !/^(sync|udevadm)/ } @events;
}

my @seen = run_deactivate( qw( sdg sdh sdi sdj ) );
is_deeply(
  \@seen,
  [ 'multipath_check', 'multipathd remove map 3624a93708476f68c18374e7700016a84', 'offline sdg sdh sdi sdj', 'array disconnect', 'delete sdg sdh sdi sdj' ],
  'the map goes, every path goes offline, the array disconnects the volume, then the paths are deleted'
);

@seen = run_deactivate();
is_deeply( \@seen, ['array disconnect'], 'a volume without local paths is still disconnected on the array, once' );

# PVE::Storage::unmap_volume calls the method with the snapshot name as the fourth argument
@events = ();
@paths  = qw( sdg );
ok( eval { $plugin->unmap_volume( 'pure', {}, 'vm-100-disk-0', 'snap1' ); 1 }, 'unmap_volume keeps the signature PVE calls: a snapshot name is not a callback' )
  or diag( $@ );
ok( !grep( { $_ eq 'array disconnect' } @events ), 'unmap_volume alone does not disconnect the volume on the array' );
like( join( "\n", @events ), qr/offline sdg\ndelete sdg/, 'unmap_volume takes the paths offline and deletes them' );

# If the array refuses to disconnect the volume, the paths that went offline are still deleted (offline paths
# left behind are worse than the race) and the error reaches the caller.
@paths  = qw( sdg sdh );
@events = ();
{
  no warnings 'redefine';
  no strict 'refs';
  local *{ "${pkg}::purestorage_volume_connection" } = sub { push @events, 'array disconnect'; die "array unreachable\n" };
  ok( !eval { $plugin->deactivate_volume( 'pure', {}, 'vm-100-disk-0' ); 1 }, 'a failed array disconnect is an error of the deactivation' );
  like( $@, qr/array unreachable/, 'the error of the array is the one reported' );
}
like( join( "\n", @events ), qr/offline sdg sdh\narray disconnect\ndelete sdg sdh/, 'the paths are deleted although the array disconnect failed' );

# A path that is still in sysfs after the delete is a stale device: it is an error, not a silent leftover.
$keep_paths = 1;
@paths      = qw( sdg sdh );
make_path( map { "$sysfs/$_" } @paths );
@events = ();
ok( !eval { $plugin->deactivate_volume( 'pure', {}, 'vm-100-disk-0' ); 1 }, 'paths that survive the delete are an error' );
like( $@, qr/sdg sdh/, 'the error names the paths that are left' );
$keep_paths = 0;
rmdir "$sysfs/$_" for qw( sdg sdh );

# The kernel gives the name of a deleted path to the next volume at once. A name in sysfs that carries the WWID of
# another volume is not a leftover of this one.
sub write_wwid {
  my ( $disk, $wwid ) = @_;
  make_path( "$sysfs/$disk/device" );
  open( my $fh, '>', "$sysfs/$disk/device/wwid" ) or die $!;
  print $fh "$wwid\n";
  close $fh;
}
$keep_paths = 1;
@paths      = qw( sdg sdh );
write_wwid( $_, 'naa.624a9370ffffffffffffffff00000001' ) for @paths;    # paths of the next volume now
@events = ();
ok( eval { $plugin->deactivate_volume( 'pure', {}, 'vm-100-disk-0' ); 1 }, 'names that carry the WWID of another volume are not leftovers' ) or diag( $@ );

write_wwid( $_, 'naa.624a93708476f68c18374e7700016a84' ) for @paths;    # still the paths of this volume
ok( !eval { $plugin->deactivate_volume( 'pure', {}, 'vm-100-disk-0' ); 1 }, 'paths that still carry the WWID of the volume are leftovers' );
like( $@, qr/sdg sdh/, 'and are named' );
$keep_paths = 0;
system( 'rm', '-rf', "$sysfs/sdg", "$sysfs/sdh" );

done_testing;
