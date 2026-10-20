#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

# Deleting the snapshot of a volume destroys it and then erases it. The array takes `replication_snapshot` only as a query
# parameter and then erases nothing but snapshots that replication uses ("The specified snapshot is not in use by
# replication" otherwise), so the erase of an ordinary snapshot must not carry it.

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';

my @actions;
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::purestorage_api_call" } = sub { push @actions, $_[1]; return {} };
}

$plugin->can( 'purestorage_snap_volume_delete' )->( $plugin, { vgname => 'vg' }, 'pure', 'daily', 'vm-100-disk-0' );

is( scalar( @actions ),             2,                              'a destroy and an erase' );
is( $actions[0]{ method },          'PATCH',                        'the snapshot is destroyed first' );
is( $actions[1]{ method },          'DELETE',                       'and erased after it' );
is( $actions[1]{ params }{ names }, $actions[0]{ params }{ names }, 'the same snapshot' );
ok( !exists $actions[1]{ params }{ replication_snapshot },                               'the erase has no replication_snapshot parameter' );
ok( !defined $actions[1]{ body } || !exists $actions[1]{ body }{ replication_snapshot }, 'and no replication_snapshot in the body, which the array ignores' );

done_testing;
