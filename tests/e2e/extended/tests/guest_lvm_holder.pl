#!/usr/bin/perl
use strict;
use warnings;

use Cwd            qw(abs_path);
use File::Basename qw(basename);
use Test::More;

use lib '..';
use Proxmox::Test::PVEInstance;
use Proxmox::Test::Util qw(skip_prerequisite);

use PVE::Storage;

# Extension of the storage plugin validation suite, written the same way. The disk of a guest carries LVM (a physical
# volume on the whole disk, a volume group with a logical volume). When the volume is activated on the host, udev runs
# `pvscan --cache -aay` for every new SCSI path, and the host may activate the volume group of the guest on a path
# before the multipath map exists. The logical volume then stands on top of the map as a holder, `multipathd remove map`
# refuses, and the deactivation fails. The activation on the host is a race: every round activates and deactivates the
# volume again, counts the rounds in which the host activated the guest volume group, and requires that no
# deactivation fails.

my $storage_id = $ENV{ PLUGIN_STORAGE_ID };
my $rounds     = $ENV{ PLUGIN_GUEST_LVM_ROUNDS } // 8;
skip_prerequisite( "no <STORAGE_ID> provided to storage-plugin-validation" ) if !$storage_id;

my $pve    = Proxmox::Test::PVEInstance->new_local();
my $client = $pve->client();
my $cfg    = PVE::Storage::config();
my $scfg   = eval { PVE::Storage::storage_config( $cfg, $storage_id ) };
skip_prerequisite( "storage '$storage_id' not configured: $@" )                     if $@ || !$scfg;
skip_prerequisite( "storage '$storage_id' does not support content type 'images'" ) if !$scfg->{ content }->{ images };

# the host filter of LVM keeps the commands of the test away from the volume, as it keeps the host away: lift it for them
my $lvm_any = q{--config 'devices { global_filter = [ "a|.*|" ] }'};

my $vmid  = $client->get( '/cluster/nextid' );
my $volid = eval { PVE::Storage::vdisk_alloc( $cfg, $storage_id, $vmid, 'raw', undef, 1024 * 1024 ) };
skip_prerequisite( "could not allocate a volume: $@" ) if !$volid;
pass( "allocated a 1 GiB volume ($volid)" );

my ( $wwn, $map );
my $activate = sub {
  PVE::Storage::activate_volumes( $cfg, [$volid] );
  my $link = PVE::Storage::path( $cfg, $volid );
  ( $wwn ) = $link =~ /wwn-0x([0-9a-f]{32})/ or die "the volume has no wwn device path: '$link'\n";
  $map = "/dev/mapper/3$wwn";
  for ( 1 .. 150 ) { last if -b $map; select( undef, undef, undef, 0.1 ) }
  -b $map or die "the multipath map $map did not appear\n";
  system( 'udevadm', 'settle', '--timeout=10' );
};

# the names of the device-mapper devices that stand on the map, partition maps of the volume left out
my $holders = sub {
  my $dm = basename( abs_path( $map ) );
  my @names;
  for my $holder ( map { basename( $_ ) } glob( "/sys/block/$dm/holders/*" ) ) {
    open( my $fh, '<', "/sys/block/$holder/dm/name" ) or next;
    chomp( my $name = <$fh> );
    push @names, $name unless $name =~ /^3$wwn-part\d+$/;
  }
  return @names;
};

eval {
  $activate->();
  my $device = "/dev/mapper/3$wwn";
  my $vg     = "pbtest$vmid";
  my $made   = system( "pvcreate -ff -y $lvm_any $device >/dev/null 2>&1 && vgcreate -y $lvm_any $vg $device >/dev/null 2>&1"
      . " && lvcreate -y $lvm_any -n lv -L 100m $vg >/dev/null 2>&1 && vgchange -an $lvm_any $vg >/dev/null 2>&1" ) == 0;
  ok( $made, "a volume group with a logical volume is made on the whole volume ($vg)" ) or die "no guest LVM\n";
  is( scalar( $holders->() ), 0, 'the logical volume is not active before the rounds' );
  PVE::Storage::deactivate_volumes( $cfg, [$volid] );

  my ( $on_host, $failed ) = ( 0, 0 );
  chomp( my $pvid = `pvs --noheadings -o pv_uuid $lvm_any $device 2>/dev/null` );
  $pvid =~ s/[\s-]//g;
  for my $round ( 1 .. $rounds ) {

    # LVM remembers a volume group it has activated (a flag in /run/lvm) and does not activate it again on the next event:
    # forget it, as a host that sees the guest volume group for the first time does
    unlink "/run/lvm/vgs_online/$vg", "/run/lvm/pvs_online/$pvid";
    $activate->();
    select( undef, undef, undef, 2 );    # pvscan of udev runs apart from the activation
    my @stuck = $holders->();
    $on_host++ if @stuck;

    my $ok    = eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ); 1 };
    my $error = $@;
    if ( !$ok ) {
      $failed++;
      diag( "round $round: the deactivation failed with the holders (@stuck): $error" );

      # take the holders away by hand, so that the next round starts from a clean volume
      system( 'dmsetup', 'remove', $_ ) for reverse sort @stuck;
      eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ) };
    }
    diag( "round $round: "
        . ( @stuck ? "the host activated the guest volume group (@stuck)" : 'the host left the volume alone' )
        . ', deactivation '
        . ( $ok ? 'ok' : 'FAILED' ) );
  }
  diag( "the host activated the guest volume group in $on_host of $rounds rounds, $failed deactivations failed" );
  is( $failed, 0, 'no deactivation fails because of a logical volume of the guest on the map' );
  1;
} or fail( "guest LVM test failed: $@" );

eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ) };
ok( eval { PVE::Storage::vdisk_free( $cfg, $volid ); 1 }, 'the volume is removed' ) or diag( $@ );

done_testing();
