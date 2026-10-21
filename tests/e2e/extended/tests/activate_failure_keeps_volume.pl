#!/usr/bin/perl
use strict;
use warnings;

use Test::More;

use lib '..';
use lib '.';
use ExtendedGuest qw(use_fio_image guest_data_device);
use Proxmox::Test::PVEInstance;
use Proxmox::Test::Util         qw(skip_prerequisite guest_name);
use Proxmox::Test::StorageGuest qw(boot_storage_guest);

use PVE::Storage;

# Extension of the storage plugin validation suite, written the same way. PVE does not undo a failed activation, so the
# plugin rolls it back itself, but only what it did: a volume it connected in this call is disconnected and unmapped, a
# volume that was connected before (a running guest holds its multipath device, a resize or a backup activates it again)
# is left as it was. When the mapping failed on such a volume and the rollback took its paths, the guest lost its disk
# and died. The mapping is made to fail here by the test (the one thing it replaces), everything else is the real plugin.

my $storage_id = $ENV{ PLUGIN_STORAGE_ID };
skip_prerequisite( "no <STORAGE_ID> provided to storage-plugin-validation" ) if !$storage_id;

my $pve    = Proxmox::Test::PVEInstance->new_local();
my $node   = $pve->get_nodename();
my $client = $pve->client();
my $cfg    = PVE::Storage::config();
my $scfg   = eval { PVE::Storage::storage_config( $cfg, $storage_id ) };
skip_prerequisite( "storage '$storage_id' not configured: $@" )                     if $@ || !$scfg;
skip_prerequisite( "storage '$storage_id' does not support content type 'images'" ) if !$scfg->{ content }->{ images };
my $plugin = PVE::Storage::Plugin->lookup( $scfg->{ type } );

# the activation of a volume with a mapping that fails; returns the error
my $failing_activation = sub {
  my ( $volname ) = @_;
  no warnings 'redefine';
  local *PVE::Storage::Custom::PureStoragePlugin::map_volume = sub { die "simulated mapping failure\n" };
  eval { $plugin->activate_volume( $storage_id, $scfg, $volname, undef, undef, {} ); 1 } and return '';
  return $@;
};

# the paths of a volume, by its WWN, and whether its multipath map exists
my $paths = sub {
  my ( $wwn ) = @_;
  return scalar grep { `cat $_ 2>/dev/null` =~ /\Q$wwn\E/ } glob( '/sys/block/sd*/device/wwid' );
};
my $map    = sub { my ( $wwn )   = @_; return -b "/dev/mapper/3$wwn" ? 1 : 0 };
my $wwn_of = sub { my ( $volid ) = @_; chomp( my $path = qx{pvesm path '$volid' 2>/dev/null} ); return $path =~ /wwn-0x([0-9a-f]{32})/ ? $1 : undef };

use_fio_image();
my $serial = 'KEEPDISK';
my $vmid   = boot_storage_guest( $pve, storage => $storage_id, name => guest_name( 'keepdisk', $storage_id ), data_disk => { size => 1, serial => $serial } );
pass( 'booted a guest with a data disk and a responsive agent' );

eval {
  # 1. the volume of a running guest: the failed mapping leaves everything as it was
  my $config = $client->get( "/nodes/$node/qemu/$vmid/config", {} );
  my ( $volid ) = $config->{ scsi1 } =~ /^([^,]+)/;
  my ( undef, $volname ) = PVE::Storage::parse_volume_id( $volid );
  my $wwn    = $wwn_of->( $volid ) or die "the data disk has no wwn path\n";
  my $before = $paths->( $wwn );
  ok( $before >= 1 && $map->( $wwn ), "the data disk of the running guest has its map and $before paths" );

  like( $failing_activation->( $volname ), qr/simulated mapping failure/, 'the activation with a failing mapping is an error' );
  is( $paths->( $wwn ), $before, 'the paths of the volume of the running guest are all there' );
  ok( $map->( $wwn ), 'and so is its multipath map' );
  my $status = $client->get( "/nodes/$node/qemu/$vmid/status/current", {} );
  is( $status->{ status }, 'running', 'the guest still runs' );
  my $read = $pve->qga_exec( $vmid, '/bin/sh', '-c',
    'dev=$(' . guest_data_device( $serial ) . '); dd if="$dev" of=/dev/null bs=4096 count=1 iflag=direct 2>&1; echo rc=$?' );
  like( $read->{ out }, qr/rc=0/, 'and its data disk reads' ) or diag( "$read->{out}$read->{err}" );

  # 2. a volume that is active and that nobody holds (a stopped guest, a resize, a backup): the same
  my $idle = PVE::Storage::vdisk_alloc( $cfg, $storage_id, $vmid, 'raw', undef, 1024 * 1024 );
  my ( undef, $idle_name ) = PVE::Storage::parse_volume_id( $idle );
  ok( eval { PVE::Storage::activate_volumes( $cfg, [$idle] ); 1 }, 'a volume is activated that nothing holds' ) or diag( $@ );
  my $idle_wwn = $wwn_of->( $idle )                                                                             or die "the idle volume has no wwn path\n";
  for ( 1 .. 150 ) { last if $map->( $idle_wwn ); select( undef, undef, undef, 0.1 ) }
  my $idle_paths = $paths->( $idle_wwn );
  ok( $idle_paths >= 1 && $map->( $idle_wwn ), "it has its map and $idle_paths paths" );
  like( $failing_activation->( $idle_name ), qr/simulated mapping failure/, 'the activation with a failing mapping is an error' );
  is( $paths->( $idle_wwn ), $idle_paths, 'all its paths are still there' );
  ok( $map->( $idle_wwn ), 'and its map' );
  eval { PVE::Storage::deactivate_volumes( $cfg, [$idle] ) };
  ok( eval { PVE::Storage::vdisk_free( $cfg, $idle ); 1 }, 'the volume is removed' ) or diag( $@ );

  # 3. a volume this call connects: the failed mapping is rolled back, nothing stays on the node
  my $new = PVE::Storage::vdisk_alloc( $cfg, $storage_id, $vmid, 'raw', undef, 1024 * 1024 );
  my ( undef, $new_name ) = PVE::Storage::parse_volume_id( $new );
  my $new_wwn = $wwn_of->( $new ) or die "the new volume has no wwn path\n";
  like( $failing_activation->( $new_name ), qr/simulated mapping failure/, 'the activation of a new volume with a failing mapping is an error' );
  is( $paths->( $new_wwn ), 0, 'no path of the new volume is left on the node' );
  ok( !$map->( $new_wwn ),                                        'and no map' );
  ok( eval { PVE::Storage::activate_volumes( $cfg, [$new] ); 1 }, 'the new volume activates afterwards' ) or diag( $@ );
  ok( $paths->( $new_wwn ) >= 1,                                  'with its paths' );
  eval { PVE::Storage::deactivate_volumes( $cfg, [$new] ) };
  ok( eval { PVE::Storage::vdisk_free( $cfg, $new ); 1 }, 'the new volume is removed' ) or diag( $@ );
  1;
} or fail( "activation failure test failed: $@" );

ok( $pve->destroy_guest( qemu => $vmid ), 'guest destroyed' );

done_testing();
