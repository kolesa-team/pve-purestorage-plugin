#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use File::Temp qw( tempdir );
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';
$plugin->can( 'purestorage_array_status' ) // BAIL_OUT( "$plugin has no purestorage_array_status" );

# PVE asks every storage for its status one after another, without a timeout. An array that does not answer holds each
# round for the HTTP timeout, so after a failure the storage is reported inactive without a call until the backoff is over.
my $dir       = tempdir( CLEANUP => 1 );
my $calls     = 0;
my $reachable = 1;
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::purestorage_array_status" } = sub {
    $calls++;
    die "array does not answer\n" unless $reachable;
    return ( 100, 60, 40, 1 );
  };
}
no warnings 'once';
local $PVE::Storage::Custom::PureStoragePlugin::STATUS_MARKER_DIR = $dir;
local $PVE::Storage::Custom::PureStoragePlugin::STATUS_BACKOFF    = 30;

sub status { return $plugin->status( 'pure', {}, undef ) }

is_deeply( [ status() ], [ 100, 60, 40, 1 ], 'a reachable array reports its space' );
is( $calls, 1, 'with one call' );
ok( !-e "$dir/pure.failed", 'and leaves no marker' );

$reachable = 0;
ok( !eval { status(); 1 }, 'a failure of the array is still an error for the caller' );
ok( -e "$dir/pure.failed", 'and leaves a marker' );

$calls = 0;
is_deeply( [ status() ], [ 0, 0, 0, 0 ], 'within the backoff the storage is inactive' );
is( $calls, 0, 'without a call to the array' );

my $old = time() - 31;
utime( $old, $old, "$dir/pure.failed" );
$reachable = 1;
is_deeply( [ status() ], [ 100, 60, 40, 1 ], 'after the backoff the array is asked again' );
ok( !-e "$dir/pure.failed", 'and the marker goes after an answer' );

done_testing();
