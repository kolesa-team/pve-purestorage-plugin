#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my %fn;
$fn{ $_ } = $plugin->can( $_ ) // BAIL_OUT( "$plugin has no $_" ) for qw(
  purestorage_snapshot_entry_from_conf
  purestorage_import_group
  purestorage_remove_snapshot_entry
  purestorage_pve_snapname_from_parent
  purestorage_pg_description_parent
  purestorage_pg_description_members
);

# --- snapshot entry must not clobber description/parent with VM notes ---
{
  my $conf = {
    name        => 'testvm',
    memory      => 1024,
    description => 'VM Notes from GUI',
    parent      => 'some-user-snap',
    snapshots   => {},
    lock        => 'migrate',
  };
  my $want  = 'PG: pgroup-auto.277; vm-100-disk-0: pgroup-auto.277.vm-100-disk-0';
  my $entry = $fn{ purestorage_snapshot_entry_from_conf }->( $conf, 1710000000, $want );
  is( $entry->{ description }, $want, 'PG description preserved despite VM notes' );
  ok( !exists $entry->{ parent }, 'parent not copied into imported snapshot entry' );
  is( $entry->{ memory }, 1024, 'machine keys still copied' );
  ok( !exists $entry->{ snapshots }, 'snapshots hash not copied' );
  ok( !exists $entry->{ lock },      'lock not copied' );
}

# --- a drive added after the snapshot is not part of the imported entry: its rollback has no member to restore from ---
{
  my $conf = {
    memory => 1024,
    scsi0  => 'pure:vm-100-disk-0,size=1G',
    scsi1  => 'pure:vm-100-disk-1,size=2G',
    scsi2  => 'other:vm-100-disk-2,size=2G',
    ide2   => 'none,media=cdrom',
  };
  my $entry = $fn{ purestorage_snapshot_entry_from_conf }->( $conf, 1710000000, 'PG: x', 'pure', { 'vm-100-disk-0' => 1 } );
  is( $entry->{ scsi0 }, $conf->{ scsi0 }, 'a drive of the snapshot is copied' );
  ok( !exists $entry->{ scsi1 }, 'a drive of this storage that is not in the snapshot is not copied' );
  is( $entry->{ scsi2 },  $conf->{ scsi2 }, 'a drive of another storage is copied' );
  is( $entry->{ ide2 },   $conf->{ ide2 },  'a drive without a volume is copied' );
  is( $entry->{ memory }, 1024,             'machine keys are copied' );
}

# --- importing a group must not take over a snapshot of the user that has the same name ---
{
  my $group = sub {
    return {
      pve_name    => 'pg-277',
      snaptime    => 1710000000,
      description => 'PG: pg.277; vm-100-disk-0: pg.277.vm-100-disk-0',
      volnames    => { 'vm-100-disk-0' => 1 }
    };
  };
  my ( %keep, $conf );

  $conf = { memory => 512, snapshots => {} };
  is( $fn{ purestorage_import_group }->( $conf, $group->(), \%keep, 'pure' ), 1,                           'a new group is imported' );
  is( $conf->{ snapshots }{ 'pg-277' }{ description },                        $group->()->{ description }, 'with the description of the group' );

  is( $fn{ purestorage_import_group }->( $conf, $group->(), \%keep, 'pure' ), 0, 'an imported group that is up to date changes nothing' );

  $conf = { snapshots => { 'pg-277' => { snaptime => 5, description => '' } } };
  %keep = ();
  $fn{ purestorage_import_group }->( $conf, $group->(), \%keep, 'pure' );
  is( $conf->{ snapshots }{ 'pg-277' }{ description }, '', 'a snapshot of the user without a description keeps it' );
  ok( exists $conf->{ snapshots }{ 'pg-277-20240309-160000' }, 'the group is imported under another name' );
  ok( $keep{ 'pg-277-20240309-160000' },                       'which is kept by the pruning' );

  # the name the group falls back to is still one that Proxmox accepts (at most 40 characters)
  my $long_group = sub { return { %{ $group->() }, pve_name => 'proxmox-pgroup-test-p-q-r' } };
  $conf = { snapshots => { 'proxmox-pgroup-test-p-q-r' => { snaptime => 5, description => '' } } };
  $fn{ purestorage_import_group }->( $conf, $long_group->(), \%keep, 'pure' );
  is( scalar( grep { length( $_ ) > 40 } keys %{ $conf->{ snapshots } } ), 0, 'the fallback name of a long group name is not longer than 40 characters' );

  $conf = { snapshots => { 'pg-277' => { snaptime => 5, description => 'my note' } } };
  $fn{ purestorage_import_group }->( $conf, $group->(), {}, 'pure' );
  is( $conf->{ snapshots }{ 'pg-277' }{ description }, 'my note', 'a snapshot of the user with a description keeps it' );
}

# --- an incomplete fetch must not drop drives: the members it has are not all the members there are ---
{
  my $conf  = { scsi0 => 'pure:vm-100-disk-0,size=1G', scsi1 => 'pure:vm-100-disk-1,size=2G' };
  my $entry = $fn{ purestorage_snapshot_entry_from_conf }->( $conf, 1710000000, 'PG: x', 'pure', undef );
  is( $entry->{ scsi1 }, $conf->{ scsi1 }, 'without a member list every drive is copied' );
}

# --- a snapshot removed by the pruning must not stay the parent of anything, as when Proxmox removes it itself ---
{
  my $conf = {
    parent    => 'pg-1',
    snapshots => { 'pg-1' => { parent => 'older' }, 'pg-2' => { parent => 'pg-1' }, 'older' => {}, 'last' => { parent => 'pg-2' } },
  };
  $fn{ purestorage_remove_snapshot_entry }->( $conf, 'pg-1' );
  ok( !exists $conf->{ snapshots }{ 'pg-1' }, 'the snapshot is gone' );
  is( $conf->{ parent },                        'older', 'the parent of the VM moves to the parent of the removed snapshot' );
  is( $conf->{ snapshots }{ 'pg-2' }{ parent }, 'older', 'so does the parent of a snapshot that followed it' );
  is( $conf->{ snapshots }{ last }{ parent },   'pg-2',  'other parents stay' );

  $fn{ purestorage_remove_snapshot_entry }->( $conf, 'older' );
  ok( !exists $conf->{ parent },                        'a removed snapshot without a parent leaves the VM without one' );
  ok( !exists $conf->{ snapshots }{ 'pg-2' }{ parent }, 'and the snapshot that followed it too' );
}

done_testing;
