#!/usr/bin/perl
use strict;
use warnings;

use Cwd   qw(abs_path);
use POSIX qw(:sys_wait_h);
use Test::More;

use lib '..';
use Proxmox::Test::PVEInstance;
use Proxmox::Test::Util qw(skip_prerequisite);

use PVE::Storage;

# Extension of the storage plugin validation suite, written the same way. A volume is activated, then something keeps
# its multipath device open (a stuck reader, a held partition) while the volume is deactivated. A map that is in use
# refuses its removal: if the user lets go within a few seconds the deactivation must succeed, and if it never does
# the deactivation must fail without leaving a half removed volume (no path offline, the connection to the host kept
# only together with its paths). When it did not wait, a failed removal used to leave stale paths behind and a
# volume that stayed connected to the node it had left.

my $storage_id = $ENV{ PLUGIN_STORAGE_ID };
skip_prerequisite( "no <STORAGE_ID> provided to storage-plugin-validation" ) if !$storage_id;

my $pve    = Proxmox::Test::PVEInstance->new_local();
my $client = $pve->client();
my $cfg    = PVE::Storage::config();
my $scfg   = eval { PVE::Storage::storage_config( $cfg, $storage_id ) };
skip_prerequisite( "storage '$storage_id' not configured: $@" )                     if $@ || !$scfg;
skip_prerequisite( "storage '$storage_id' does not support content type 'images'" ) if !$scfg->{ content }->{ images };

my $vmid  = $client->get( '/cluster/nextid' );
my $volid = eval { PVE::Storage::vdisk_alloc( $cfg, $storage_id, $vmid, 'raw', undef, 1024 * 1024 ) };
skip_prerequisite( "could not allocate a volume: $@" ) if !$volid;
pass( "allocated a 1 GiB volume ($volid)" );

my @holders;
my $hold = sub {
  my ( $device ) = @_;
  my $pid = fork() // die "fork: $!\n";
  if ( !$pid ) {
    open( my $fh, '<', $device ) or exit 1;
    sleep 3600;
    exit 0;
  }
  push @holders, $pid;
  sleep 1;
  return $pid;
};
my $release = sub {
  my ( $pid ) = @_;
  kill 'TERM', $pid;
  waitpid( $pid, 0 );
};

# The paths of the volume as sysfs lists them, found by the WWID.
my $paths = sub {
  my ( $wwn ) = @_;
  my @found = grep { `cat $_ 2>/dev/null` =~ /\Q$wwn\E/ } glob( '/sys/block/sd*/device/wwid' );
  return scalar @found;
};

eval {
  PVE::Storage::activate_volumes( $cfg, [$volid] );
  my $link = PVE::Storage::path( $cfg, $volid );
  my ( $wwn ) = $link =~ /wwn-0x([0-9a-f]{32})/;
  skip_prerequisite( "the volume has no wwn device path: '$link'" ) if !$wwn;

  # the map of the volume does not have to exist the moment the activation returns: how long does it take?
  my $map         = "/dev/mapper/3$wwn";
  my $appeared    = 0;
  my $waited_from = time();
  for ( 1 .. 150 ) {
    if ( -b $map ) { $appeared = 1; last }
    select( undef, undef, undef, 0.1 );
  }
  diag( sprintf( 'the multipath map %s after %.1f s', $appeared ? 'appeared' : 'did not appear', time() - $waited_from ) );
  my $device = abs_path( $map );
  my $before = $paths->( $wwn );
  ok( $before >= 1 && -b $device, "the volume is active with $before paths, multipath device $device" );

  # 1. the holder lets go while the deactivation waits
  my $holder = $hold->( $device );
  my $helper = fork() // die "fork: $!\n";
  if ( !$helper ) {
    sleep 8;
    kill 'TERM', $holder;
    exit 0;
  }
  my $started = time();
  my $ok      = eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ); 1 };
  my $took    = time() - $started;
  waitpid( $helper, 0 );
  waitpid( $holder, 0 );
  ok( $ok, "the deactivation waits for a map that is released after a few seconds (took $took s)" ) or diag( $@ );
  is( $paths->( $wwn ), 0, 'no path of the volume is left after the deactivation' ) if $ok;

  # 2. a partition map is held and never released: the deactivation fails and leaves the volume as it was
  PVE::Storage::activate_volumes( $cfg, [$volid] ) if $ok;
  for ( 1 .. 150 ) { last if -b $map; select( undef, undef, undef, 0.1 ) }
  $device = abs_path( $map );

  # a partition of the volume, as the host maps it (a child of the multipath device), is held: what LVM or a mount
  # inside a partition of a guest disk does, and the kind of busy map seen in production
  system( "printf 'label: gpt\\n,,L\\n' | sfdisk --quiet $device >/dev/null 2>&1; kpartx -a $device >/dev/null 2>&1; udevadm settle" );
  chomp( my $child = `lsblk -nlo NAME $device | sed -n 2p` );
  ok( $child ne '', "the partition of the volume is mapped on the host ($child)" ) or die "no partition map\n";
  $holder = $hold->( "/dev/mapper/$child" );
  $ok     = eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ); 1 };
  ok( !$ok, 'the deactivation of a map that stays in use is an error' );
  my $kept = $paths->( $wwn );
  ok( $kept >= 1 && -b $device, "the volume keeps its device and all $kept paths after the refused deactivation" );
  my $offline = `grep -l offline /sys/block/sd*/device/state 2>/dev/null | wc -l`;
  chomp $offline;
  is( $offline + 0, 0, 'no path of any volume was left offline' );

  # 3. once released, the deactivation goes through
  $release->( $holder );
  $ok = eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ); 1 };
  ok( $ok, 'the deactivation succeeds once the map is released' ) or diag( $@ );
  is( $paths->( $wwn ), 0, 'no path of the volume is left after the second deactivation' );

  # 4. LVM inside a partition of the volume, activated on the host (the host scans guest disks unless it is told not
  # to, see troubleshooting): an active logical volume holds the partition map and the map cannot be removed
  PVE::Storage::activate_volumes( $cfg, [$volid] );
  for ( 1 .. 150 ) { last if -b $map; select( undef, undef, undef, 0.1 ) }
  $device = abs_path( $map );
  system( "kpartx -a $device >/dev/null 2>&1; udevadm settle" );
  chomp( my $part = `lsblk -nlo NAME $device | sed -n 2p` );
  my $vg  = "pbtest$vmid";
  my $lvm = $part ne ''
    && system(
"pvcreate -ff -y /dev/mapper/$part >/dev/null 2>&1 && vgcreate -y $vg /dev/mapper/$part >/dev/null 2>&1 && lvcreate -y -n lv -L 100m $vg >/dev/null 2>&1 && vgchange -ay $vg >/dev/null 2>&1"
    ) == 0;

  if ( !$lvm ) {
    diag( "LVM does not take the partition ($part): the LVM filter of the host excludes the volume, as the documentation advises" );
  } else {
    $ok = eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ); 1 };
    ok( $ok, 'the deactivation succeeds although a logical volume of the guest is active on the host' ) or diag( $@ );
    system( "vgchange -an $vg >/dev/null 2>&1; vgremove -f $vg >/dev/null 2>&1; pvremove -ff -y /dev/mapper/$part >/dev/null 2>&1" );
    $ok = eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ); 1 } if !$ok;
    ok( $ok, 'the deactivation succeeds once the logical volume is deactivated' ) or diag( $@ );
  }
  1;
} or fail( "busy map test failed: $@" );

$release->( $_ ) for @holders;
eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ) };
ok( eval { PVE::Storage::vdisk_free( $cfg, $volid ); 1 }, 'the volume is removed' ) or diag( $@ );

done_testing();
