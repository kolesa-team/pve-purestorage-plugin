#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';

# A linked clone from a snapshot restores the new volume from the snapshot on the array. A snapshot imported from a
# protection group has the array name PGROUP.SUFFIX.<volume>, which is not what the name of a Proxmox snapshot gives
# (<volume>.snap-<snapshot>): the clone has to restore from the exact name, as the rollback does.
my @restores;
my $imported = 0;
my $resolved = 'pgroup-auto.277.vm-100-disk-0';
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::find_free_diskname" }                = sub { return 'vm-200-disk-0' };
  *{ "${pkg}::purestorage_snap_is_pg_imported" }   = sub { return $imported };
  *{ "${pkg}::purestorage_resolve_imported_snap" } = sub { return $resolved };
  *{ "${pkg}::purestorage_volume_restore" }        = sub { shift; push @restores, [@_] };
}

sub clone { return $plugin->clone_image( {}, 'pure', 'vm-100-disk-0', 200, 'pgroup-auto-277' ) }

$imported = 0;
@restores = ();
is( clone(), 'vm-200-disk-0', 'the clone of a native snapshot gets the new volume name' );
is_deeply(
  $restores[0],
  [ {}, 'pure', 'vm-200-disk-0', 'vm-100-disk-0', 'pgroup-auto-277', undef, undef ],
  'a native snapshot is restored by its Proxmox name'
);

$imported = 1;
@restores = ();
is( clone(), 'vm-200-disk-0', 'the clone of an imported snapshot gets the new volume name' );
is_deeply(
  $restores[0],
  [ {}, 'pure', 'vm-200-disk-0', 'vm-100-disk-0', 'pgroup-auto-277', undef, $resolved ],
  'an imported snapshot is restored by its exact array name'
);

$resolved = undef;
@restores = ();
ok( !eval { clone(); 1 }, 'an imported snapshot that is not on the array fails the clone' );
like( $@, qr/pgroup-auto-277.*not found/, 'the error names the snapshot' );
is( scalar @restores, 0, 'nothing is restored then' );

done_testing();
