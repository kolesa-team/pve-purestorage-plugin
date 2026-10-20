#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';

# PVE does not undo a failed activation: the volume stays connected on the array and its paths stay on the node.
# The plugin deactivates the volume itself when the second step (the local mapping) fails.
my @events;
my $map_error;
my $rollback_error;
my $connected_now = 1;    # what the array connection says: 1 created now, 0 it was there already
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::purestorage_volume_connection" } = sub { push @events, 'array connect'; return $connected_now };
  *{ "${pkg}::map_volume" }                    = sub { push @events, 'map';           die $map_error      if $map_error;      return '/dev/x' };
  *{ "${pkg}::deactivate_volume" }             = sub { push @events, 'deactivate';    die $rollback_error if $rollback_error; return 1 };
}

sub activate {
  ( $map_error, $rollback_error, @events ) = ( shift, shift, () );
  $connected_now = shift // 1;
  my $ok = eval { $plugin->activate_volume( 'pure', {}, 'vm-100-disk-0' ); 1 };
  return ( $ok, $@ );
}

my ( $ok ) = activate( undef, undef );
ok( $ok, 'a volume that maps is activated' );
is_deeply( \@events, [ 'array connect', 'map' ], 'a successful activation does not roll anything back' );

my $error;
( $ok, $error ) = activate( "map timeout\n", undef );
ok( !$ok, 'a failed mapping is an error of the activation' );
is( $error, "map timeout\n", 'the error of the mapping is the one reported' );
is_deeply( \@events, [ 'array connect', 'map', 'deactivate' ], 'the volume is deactivated after the failed mapping' );

( $ok, $error ) = activate( "map timeout\n", "array unreachable\n" );
is( $error, "map timeout\n", 'a failed rollback does not hide the error of the mapping' );

# A volume that was connected before this call may be in use (a running guest holds its multipath device, a resize or a
# backup activates it again): when the mapping fails there, nothing is rolled back, or the guest loses its disk.
( $ok, $error ) = activate( "map timeout\n", undef, 0 );
ok( !$ok, 'a failed mapping of a volume that was connected already is still an error' );
is( $error, "map timeout\n", 'with the error of the mapping' );
is_deeply( \@events, [ 'array connect', 'map' ], 'but the volume is left as it was: no deactivation' );

done_testing;
