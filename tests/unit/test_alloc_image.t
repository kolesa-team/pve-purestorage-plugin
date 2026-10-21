#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $alloc  = $plugin->can( 'alloc_image' ) // BAIL_OUT( "$plugin has no alloc_image" );

# The array takes the volume name as given and accepts letters, digits, '_' and '-' only, so a ".raw" suffix
# that the content API of PVE appends must not reach it.
my @created;
{
  no warnings 'redefine';
  *PVE::Storage::Custom::PureStoragePlugin::purestorage_create_volume = sub {
    my ( $class, $scfg, $name, $size ) = @_;
    push @created, [ $name, $size ];
    return 1;
  };
}

sub allocate {
  my ( $name, $fmt, $size ) = @_;
  @created = ();
  my $volname = eval { $plugin->alloc_image( 'pure', {}, 100, $fmt // 'raw', $name, $size // 1024 ) };
  return ( $volname, $@ );
}

my ( $volname ) = allocate( 'vm-100-disk-0.raw' );
is( $volname,       'vm-100-disk-0', 'the .raw suffix is cut from the returned name' );
is( $created[0][0], 'vm-100-disk-0', 'the array gets the name without the .raw suffix' );

( $volname ) = allocate( 'vm-100-disk-0' );
is( $volname,       'vm-100-disk-0', 'a name without a suffix is kept' );
is( $created[0][0], 'vm-100-disk-0', 'the array gets a name without a suffix as it is' );

( $volname ) = allocate( 'vm-100-cloudinit.raw' );
is( $volname, 'vm-100-cloudinit', 'the suffix is cut from a cloud-init volume name too' );

( $volname ) = allocate( 'vm-100-disk-0.raw', 'raw', 2048 );
is( $created[0][1], 2048 * 1024, 'the size in KiB goes to the array in bytes' );

my ( undef, $error ) = allocate( 'vm-100-disk-0.qcow2', 'qcow2' );
like( $error, qr/Unsupported format \(qcow2\)/, 'a format other than raw is refused' );
is( scalar @created, 0, 'nothing is created for a refused format' );

( undef, $error ) = allocate( 'vm-200-disk-0.raw' );
like( $error, qr/Illegal name/, 'a name of another VM is refused' );
is( scalar @created, 0, 'nothing is created for a refused name' );

done_testing;
