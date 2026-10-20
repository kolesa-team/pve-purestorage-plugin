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
  purestorage_array_snapshot_is_pve_ui_snapshot
  purestorage_pgroup_parent_name
  purestorage_pve_snapname_from_parent
  purestorage_pg_description_parent
  purestorage_pg_description_members
  purestorage_unique_group_names
);

# --- sanitize ---
is( $fn{ purestorage_pve_snapname_from_parent }->( 'pgroup-auto.277' ),      'pgroup-auto-277',      'sanitize pgroup-auto.277' );
is( $fn{ purestorage_pve_snapname_from_parent }->( 'pgroup-auto.mysuffix' ), 'pgroup-auto-mysuffix', 'sanitize custom suffix' );
like( $fn{ purestorage_pve_snapname_from_parent }->( 'pgroup-auto.277' ), qr/^[a-zA-Z][a-zA-Z0-9_-]*$/, 'sanitized name matches PVE configid charset' );

# --- parent parse from name ---
is( $fn{ purestorage_pgroup_parent_name }->( { name => 'pgroup-auto.277.vm-100-disk-0' }, 'vm-100-disk-0' ), 'pgroup-auto.277', 'parent from member name' );
is( $fn{ purestorage_pgroup_parent_name }->( { name => 'pgroup-auto.277.pod::vm-100-disk-0' }, 'pod::vm-100-disk-0' ),
  'pgroup-auto.277', 'parent with pod:: volume source' );
is( $fn{ purestorage_pgroup_parent_name }->( { name => 'vm-100-disk-0.4166' }, 'vm-100-disk-0' ), undef, 'volume-only snap has no pgroup parent' );
is( $fn{ purestorage_pgroup_parent_name }->( { name => 'pgroup-auto.277.vm-100-disk-0', snapshot_group => { name => 'pgroup-auto.277' } }, 'vm-100-disk-0' ),
  'pgroup-auto.277', 'prefer snapshot_group.name' );

# --- PVE UI skip ---
ok(
  $fn{ purestorage_array_snapshot_is_pve_ui_snapshot }->( { _prefix => '' }, 'vm-100-disk-0', { name => 'vm-100-disk-0.snap-daily', suffix => 'snap-daily' } ),
  'skip .snap-daily'
);
ok(
  !$fn{ purestorage_array_snapshot_is_pve_ui_snapshot }
    ->( { _prefix => '' }, 'vm-100-disk-0', { name => 'pgroup-auto.277.vm-100-disk-0', suffix => '277.vm-100-disk-0' } ),
  'do not skip pgroup member'
);

# --- description parent ---
is( $fn{ purestorage_pg_description_parent }->( 'PG: pgroup-auto.277; vol: snap' ), 'pgroup-auto.277', 'parse PG parent from description' );
is( $fn{ purestorage_pg_description_parent }->( 'user note' ),                      undef,             'non-PG description' );

# --- description members parse ---
{
  my $desc = 'PG: pgroup-auto.277; vm-100-disk-0: pgroup-auto.277.vm-100-disk-0; vm-100-disk-1: pgroup-auto.277.vm-100-disk-1';
  my $m    = $fn{ purestorage_pg_description_members }->( $desc );
  is( $m->{ 'vm-100-disk-0' }, 'pgroup-auto.277.vm-100-disk-0', 'member disk-0 from description' );
  is( $m->{ 'vm-100-disk-1' }, 'pgroup-auto.277.vm-100-disk-1', 'member disk-1 from description' );
  is( scalar keys %$m,         2,                               'two members parsed' );
  is_deeply( $fn{ purestorage_pg_description_members }->( 'user note' ), {}, 'non-PG description has no members' );
}

# --- a protection group in a pod: its names carry "::" ---
{
  my $name = $fn{ purestorage_pve_snapname_from_parent }->( 'proxmox-pgroup-test-pod::pgpod.1' );
  like( $name, qr/^[a-zA-Z][a-zA-Z0-9_-]*$/, 'the Proxmox snapshot name of a group in a pod is valid' );
  is( $name, 'proxmox-pgroup-test-pod--pgpod-1', 'with the pod separator and the dot replaced' );

  my $desc =
    'PG: proxmox-pgroup-test-pod::pgpod.1; proxmox-pgroup-test-pod::vm-9992-disk-0: proxmox-pgroup-test-pod::pgpod.1.proxmox-pgroup-test-pod::vm-9992-disk-0';
  is( $fn{ purestorage_pg_description_parent }->( $desc ), 'proxmox-pgroup-test-pod::pgpod.1', 'the group is read from the description of a pod snapshot' );
  is_deeply(
    $fn{ purestorage_pg_description_members }->( $desc ),
    { 'proxmox-pgroup-test-pod::vm-9992-disk-0' => 'proxmox-pgroup-test-pod::pgpod.1.proxmox-pgroup-test-pod::vm-9992-disk-0' },
    'the members of a pod snapshot are read whole'
  );
}

# --- two groups that give the same Proxmox name: the later one gets the time of its snapshot in the name ---
{
  my $name   = $fn{ purestorage_pve_snapname_from_parent };
  my @groups = map { { parent => $_->[0], pve_name => $name->( $_->[0] ), snaptime => $_->[1] } }
    ( [ 'a-b.c', 1710000000 ], [ 'a.b-c', 1710003600 ], [ 'x.1', 1710000000 ] );
  $fn{ purestorage_unique_group_names }->( \@groups );
  is_deeply(
    [ map { $_->{ pve_name } } @groups ],
    [ 'a-b-c', 'a-b-c-20240309-170000', 'x-1' ],
    'the first group keeps the name, the second one gets the date and time of its snapshot (UTC)'
  );

  my @same = map { { parent => 'a-b.c', pve_name => 'a-b-c', snaptime => $_ } } ( 1710000000, 1710000000 );
  $fn{ purestorage_unique_group_names }->( \@same );
  isnt( $same[0]{ pve_name }, $same[1]{ pve_name }, 'groups that also share the second of their snapshots still get different names' );

  # Proxmox refuses a snapshot name longer than 40 characters in every API call (clone, rollback, delete)
  my $long = 'proxmox-pgroup-test-p-q-r';
  my @long = map { { parent => $_->[0], pve_name => $long, snaptime => $_->[1] } } ( [ 'a', 1710000000 ], [ 'b', 1710003600 ], [ 'c', 1710003600 ] );
  $fn{ purestorage_unique_group_names }->( \@long );
  is( scalar( grep { length( $_->{ pve_name } ) > 40 } @long ),    0, 'no name of a colliding group is longer than 40 characters' );
  is( scalar( keys %{ { map { $_->{ pve_name } => 1 } @long } } ), 3, 'the shortened names are still different' );
  like( $long[1]{ pve_name }, qr/-20240309-170000$/, 'the date and time stay at the end of a shortened name' );
  unlike( $long[1]{ pve_name }, qr/--/, 'the cut does not leave a double dash before the date' );

  my @too_long = ( { parent => 'x', pve_name => 'p' x 60, snaptime => 1710000000 } );
  $fn{ purestorage_unique_group_names }->( \@too_long );
  is( length( $too_long[0]{ pve_name } ), 40, 'a single group name longer than 40 characters is cut to 40' );
}

# --- the name of a member snapshot of a group in a pod, as the array gives it: the pod is not repeated in front of the volume ---
is(
  $fn{ purestorage_pgroup_parent_name }->( { name => 'proxmox-pgroup-test-pod::pgpod.1.vm-9992-disk-0' }, 'proxmox-pgroup-test-pod::vm-9992-disk-0' ),
  'proxmox-pgroup-test-pod::pgpod.1',
  'parent of a member snapshot in a pod'
);
is( $fn{ purestorage_pgroup_parent_name }->( { name => 'proxmox-pgroup-test-pod::vm-9992-disk-0.4166' }, 'proxmox-pgroup-test-pod::vm-9992-disk-0' ),
  undef, 'a volume-only snapshot in a pod has no pgroup parent' );

done_testing;
