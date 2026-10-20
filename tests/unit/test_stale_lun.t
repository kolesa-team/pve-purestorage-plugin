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
$plugin->can( 'heal_stale_paths' ) // BAIL_OUT( "$plugin has no heal_stale_paths" );

# The array hands the LUN number of a removed volume to the next volume, and a device of the old volume that is
# still on that LUN keeps its old WWID: a host scan does not read it again. Such a device is found by the WWID the
# device answers now, and only a device that answers another WWID is rescanned.
my $new    = '3624a93708476f68c18374e7700016a84';
my $old    = '3624a93708476f68c18374e7700016a83';
my $sysfs  = tempdir( CLEANUP => 1 );
my %live   = ();                                    # what the device answers; undef: no answer
my @events = ();

sub disk {
  my ( $name, $lun, $cached ) = @_;
  make_path( "$sysfs/$name", "$sysfs/hosts/3:0:0:$lun" );
  symlink( "$sysfs/hosts/3:0:0:$lun", "$sysfs/$name/device" );
  open( my $fh, '>', "$sysfs/$name/device/wwid" ) or die $!;
  print { $fh } "naa.$cached\n";
  close $fh;
}
disk( 'sdg', 5, substr( $new, 1 ) );                # path of the new volume
disk( 'sdh', 5, substr( $old, 1 ) );                # stale, the LUN now holds the new volume
disk( 'sdi', 5, substr( $old, 1 ) );                # stale, no answer: a path that is down is not proof
disk( 'sdj', 7, substr( $old, 1 ) );                # stale, but on another LUN
disk( 'sdk', 6, substr( $old, 1 ) );                # same cached WWID as live: nothing to heal
disk( 'sdl', 9, 'deadbeef' x 4 );                   # not a Pure disk

{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::scsi_live_wwid" }      = sub { exists $live{ $_[0] } ? $live{ $_[0] } : undef };
  *{ "${pkg}::block_device_action" } = sub { push @events, "$_[0] @_[1..$#_]" };
}
no warnings 'once';
local $PVE::Storage::Custom::PureStoragePlugin::SYSFS_BLOCK = $sysfs;

%live   = ( sdh => $new, sdj => $new, sdk => $old );
@events = ();
$plugin->can( 'heal_stale_paths' )->( $new, 5 );
is_deeply( \@events, ['rescan sdh'], 'only the device on the LUN of the volume that answers another WWID is rescanned' );

@events = ();
$plugin->can( 'heal_stale_paths' )->( $new );
is_deeply( [ sort @events ], [ 'rescan sdh', 'rescan sdj' ], 'without a LUN every Pure device is checked, and the ones that answer the old WWID stay' );

# map_volume: the path of the new volume shows up only after the stale device is rescanned
my $link = "$sysfs/by-id-link";
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::block_device_action" } = sub { push @events, "$_[0] @_[1..$#_]"; -l $link or symlink( "$sysfs/sdg", $link ) or die $! };
}
local $PVE::Storage::Custom::PureStoragePlugin::STALE_PATH_WAIT = 0.3;
%live   = ( sdh => $new, sdj => $new, sdk => $old );
@events = ();
$plugin->can( 'wait_for_volume_path' )->( $new, $link, 'vm-100-disk-0' );
is_deeply( [ sort @events ], [ 'rescan sdh', 'rescan sdj' ], 'a path that does not show up makes every Pure device be checked, then the wait goes on' );

unlink $link;
symlink( "$sysfs/sdg", $link ) or die $!;
@events = ();
$plugin->can( 'wait_for_volume_path' )->( $new, $link, 'vm-100-disk-0' );
is_deeply( \@events, ['rescan sdh'], 'a path that shows up makes only the devices on its LUN be checked' );

# A wait that may end without the thing it waits for (the path of a new volume within the first seconds) is not an
# error: no ERROR line in the task log, the caller decides.
{
  my $stderr = '';
  open( my $capture, '>', \$stderr ) or die $!;
  local *STDERR = $capture;
  my $found = $plugin->can( 'wait_for' )->( sub { 0 }, 'something that never comes', 0.2, 0.1, 1 );
  is( $found, 0, 'a wait that is not fatal returns false on a timeout' );
  unlike( $stderr, qr/ERROR/, 'and logs no error' );
}

# The check of the devices on one LUN reads the cached WWID of those devices only: it runs on every activation, and
# a node has hundreds of paths.
{
  my @reads;
  no warnings 'redefine';
  no strict 'refs';
  my $real = \&{ "${pkg}::file_read_firstline" };
  local *{ "${pkg}::file_read_firstline" } = sub { push @reads, $_[0]; return $real->( @_ ) };
  %live = ( sdh => $new );
  $plugin->can( 'heal_stale_paths' )->( $new, 5 );
  is( scalar @reads, 3, 'only the three devices on the LUN had their cached WWID read' );
}

# The LUN of a mapped volume, from the disk its by-id link leads to, or from the first path of its multipath map.
make_path( "$sysfs/dm-3/slaves" );
open( my $slave, '>', "$sysfs/dm-3/slaves/sdh" ) or die $!;
close $slave;
symlink( "$sysfs/dm-3", "$sysfs/by-id-dm" ) or die $!;
is( $plugin->can( 'volume_lun' )->( "$sysfs/sdg" ),      5,     'the LUN of a volume whose link leads to a path' );
is( $plugin->can( 'volume_lun' )->( "$sysfs/by-id-dm" ), 5,     'the LUN of a volume whose link leads to a multipath device' );
is( $plugin->can( 'volume_lun' )->( "$sysfs/missing" ),  undef, 'no LUN for a link that leads nowhere' );

done_testing();
