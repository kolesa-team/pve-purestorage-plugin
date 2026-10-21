#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(basename);
use Test::More;

use lib '..';
use Proxmox::Test::PVEInstance;
use Proxmox::Test::Util qw(skip_prerequisite);

use PVE::Storage;

# Extension of the storage plugin validation suite, written the same way. A volume leaves a node the way it did in
# production after a failed deactivation: its multipath map is gone and the array has disconnected it, but its SCSI
# devices stay on the node. The array hands the freed LUN number to the next volume, and the old device still sits on
# that LUN with the old WWID, which a scan does not refresh. The next volume must still become usable, and nothing of
# the old volume may be left on the node.

my $storage_id = $ENV{ PLUGIN_STORAGE_ID };
skip_prerequisite( "no <STORAGE_ID> provided to storage-plugin-validation" ) if !$storage_id;

my $pve    = Proxmox::Test::PVEInstance->new_local();
my $client = $pve->client();
my $cfg    = PVE::Storage::config();
my $scfg   = eval { PVE::Storage::storage_config( $cfg, $storage_id ) };
skip_prerequisite( "storage '$storage_id' not configured: $@" )                     if $@ || !$scfg;
skip_prerequisite( "storage '$storage_id' does not support content type 'images'" ) if !$scfg->{ content }->{ images };
my $plugin = PVE::Storage::Plugin->lookup( $scfg->{ type } );
my $vmid   = $client->get( '/cluster/nextid' );

# SCSI devices of a volume by its WWN, with the LUN number each one has.
my $devices = sub {
  my ( $wwn ) = @_;
  my %found;
  for my $file ( glob( '/sys/block/sd*/device/wwid' ) ) {
    next if `cat $file 2>/dev/null` !~ /\Q$wwn\E/;
    my ( $disk ) = $file                                                   =~ m{/(sd\w+)/device/wwid};
    my ( $lun )  = basename( readlink( "/sys/block/$disk/device" ) // '' ) =~ /:(\d+)$/;
    $found{ $disk } = $lun;
  }
  return \%found;
};
my $wwn_of = sub { my ( $link ) = @_; return $link =~ /wwn-0x([0-9a-f]{32})/ ? $1 : undef };

my @volids;
my $alloc = sub {
  my $volid = PVE::Storage::vdisk_alloc( $cfg, $storage_id, $vmid, 'raw', undef, 1024 * 1024 ) or die "no volume\n";
  push @volids, $volid;
  return $volid;
};

my ( $stale, $wwn_a, $wwn_b );
eval {
  my $a = $alloc->();
  PVE::Storage::activate_volumes( $cfg, [$a] );
  $wwn_a = $wwn_of->( scalar PVE::Storage::path( $cfg, $a ) ) or die "volume A has no wwn path\n";
  for ( 1 .. 150 ) { last if -b "/dev/mapper/3$wwn_a"; select( undef, undef, undef, 0.1 ) }
  $stale = $devices->( $wwn_a );
  my @luns = values %$stale;
  ok( scalar( keys %$stale ) >= 1, 'volume A is active with ' . scalar( keys %$stale ) . " devices on LUN @luns[0]" );

  # what a failed deactivation leaves: no map, no connection on the array, the devices still on the node
  system( "multipathd remove map 3$wwn_a >/dev/null 2>&1" );
  my ( undef, $a_name ) = PVE::Storage::parse_volume_id( $a );
  $plugin->purestorage_volume_connection( $storage_id, $scfg, $a_name, 0 );
  is( scalar( keys %{ $devices->( $wwn_a ) } ), scalar( keys %$stale ), 'the devices of volume A are still on the node after its disconnect' );

  # the next volume gets the LUN number the array has just freed
  my $b                = $alloc->();
  my $activated        = eval { PVE::Storage::activate_volumes( $cfg, [$b] ); 1 };
  my $activation_error = $@;
  $wwn_b = $wwn_of->( scalar PVE::Storage::path( $cfg, $b ) );
  my $b_luns   = $wwn_b ? [ sort values %{ $devices->( $wwn_b ) } ] : [];
  my $same_lun = grep {
    my $l = $_;
    grep { $_ eq $l } @$b_luns
  } values %$stale;
  if ( !$activated ) {
    ok( !$same_lun, 'volume B was activated' ) or diag( "volume B did not activate: $activation_error" );
  } else {
    diag( $same_lun ? 'volume B got the LUN of volume A' : 'volume B got another LUN than volume A: no collision this time' );
    ok( $activated, 'volume B was activated' );
    is( scalar( keys %{ $devices->( $wwn_a ) } ), 0, 'no device of volume A is left on the node' ) if $same_lun;
  }
  1;
} or diag( "stale LUN test failed: $@" );

# the devices of volume A that nothing healed go away by hand, so that the node is left clean; the ones healed are
# paths of volume B now and go with its deactivation
if ( $wwn_a ) {
  for my $disk ( keys %{ $devices->( $wwn_a ) } ) {
    system( "echo 1 > /sys/block/$disk/device/delete 2>/dev/null" );
  }
}
for my $volid ( reverse @volids ) {
  eval { PVE::Storage::deactivate_volumes( $cfg, [$volid] ) };
}
ok( eval { PVE::Storage::vdisk_free( $cfg, $_ ); 1 }, "volume $_ is removed" ) || diag( $@ ) for reverse @volids;
is( join( ' ', grep { -e "/dev/mapper/3$_" } grep { defined } $wwn_a, $wwn_b ), '', 'no multipath map of the two volumes is left' );

done_testing();
