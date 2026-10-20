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
my $paths  = $plugin->can( 'block_device_paths_by_wwid' ) // BAIL_OUT( "$plugin has no block_device_paths_by_wwid" );

# A volume is visible as one SCSI disk per path. The by-id link can point at a single path when the multipath
# map is not up, so the paths of a volume are found by its WWID, not by that link.
my $sysfs = tempdir( CLEANUP => 1 );

sub disk {
  my ( $name, $wwid ) = @_;
  make_path( "$sysfs/$name/device" );
  open( my $fh, '>', "$sysfs/$name/device/wwid" ) or die $!;
  print { $fh } "$wwid\n";
  close $fh;
}
disk( 'sdg', 'naa.624a93708476f68c18374e7700016a84' );
disk( 'sdh', 'naa.624a93708476f68c18374e7700016a84' );
disk( 'sdi', 'naa.624a93708476f68c18374e7700016a85' );
disk( 'sdj', 'naa.624a93708476f68c18374e7700016a84' );
make_path( "$sysfs/dm-3/dm" );       # not a SCSI disk
make_path( "$sysfs/sda/device" );    # a disk without a wwid file

no warnings 'once';
local $PVE::Storage::Custom::PureStoragePlugin::SYSFS_BLOCK = $sysfs;

is_deeply( [ sort $paths->( '3624a93708476f68c18374e7700016a84' ) ], [qw( sdg sdh sdj )], 'every path of the volume is found' );
is_deeply( [ $paths->( '3624a93708476f68c18374e7700016a85' ) ],      ['sdi'],             'a volume with one path' );
is_deeply( [ $paths->( '3624a93708476f68c18374e7700016aff' ) ],      [],                  'a volume that is not mapped has no paths' );

# A resize rescans, an unmap removes: both act on every path of the volume, not on the slaves of the device the
# by-id link points at (a single path while the map is not up).
my $lun_paths = $plugin->can( 'lun_paths' ) // BAIL_OUT( "$plugin has no lun_paths" );

is_deeply( [ $lun_paths->( '3624a93708476f68c18374e7700016a84', 'sdg' ) ], [qw( sdg sdh sdj )], 'a link to one path still gives every path' );
is_deeply( [ $lun_paths->( '3624a93708476f68c18374e7700016a84', qw( sdj sdg sdh ) ) ],
  [qw( sdg sdh sdj )], 'slaves that are all the paths are listed once, sorted' );
is_deeply( [ $lun_paths->( '3624a93708476f68c18374e7700016aff', 'sdk' ) ], ['sdk'], 'a slave the sysfs does not report is kept' );
is_deeply( [ $lun_paths->( '3624a93708476f68c18374e7700016aff' ) ],        [],      'no slaves and no paths give nothing' );

# Everything that reads the sysfs reads it under $SYSFS_BLOCK: a test (or a node with another root) redirects all of it.
open( my $size, '>', "$sysfs/sdg/size" ) or die $!;
print { $size } "2048\n";
close $size;
is( $plugin->can( 'get_device_size' )->( '/dev/sdg' ), 2048 * 512, 'the size of a disk is read under SYSFS_BLOCK' );

make_path( "$sysfs/dm-3/slaves" );
open( my $slave, '>', "$sysfs/dm-3/slaves/sdh" ) or die $!;
close $slave;
symlink( "$sysfs/dm-3", "$sysfs/by-id-dm" ) or die $!;
my ( undef, @slaves ) = $plugin->can( 'block_device_slaves' )->( "$sysfs/by-id-dm" );
is_deeply( \@slaves, ['sdh'], 'the slaves of a multipath device are read under SYSFS_BLOCK' );

done_testing;
