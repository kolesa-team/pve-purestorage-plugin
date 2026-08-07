#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 31;

# Standalone copies of PureStoragePlugin helpers (plugin requires PVE modules).

sub purestorage_array_snapshot_is_pve_ui_snapshot {
  my ( $scfg, $volname, $snap_row ) = @_;
  my $suffix = $snap_row->{ suffix } // '';
  return 1 if $suffix =~ /^(snap-|veeam-)/;
  my $base      = ( $scfg->{ _prefix } // '' ) . $volname;
  my $snap_name = $snap_row->{ name } // '';
  return 0 unless length( $base ) && index( $snap_name, "$base." ) == 0;
  my $rest = substr( $snap_name, length( $base ) + 1 );
  return ( $rest =~ /^(snap-|veeam-)/ ) ? 1 : 0;
}

sub purestorage_pgroup_parent_name {
  my ( $snap_row, $source_name ) = @_;
  for my $key ( qw(snapshot_group group) ) {
    my $ref = $snap_row->{ $key };
    if ( ref( $ref ) eq 'HASH' && length( $ref->{ name } // '' ) ) {
      return $ref->{ name };
    }
  }
  my $snap_name = $snap_row->{ name } // '';
  return undef unless length( $source_name // '' ) && length( $snap_name );
  my $tail = '.' . $source_name;
  return undef unless length( $snap_name ) > length( $tail );
  return undef unless substr( $snap_name, -length( $tail ) ) eq $tail;
  my $parent = substr( $snap_name, 0, length( $snap_name ) - length( $tail ) );
  return undef unless index( $parent, '.' ) >= 0;
  return $parent;
}

sub purestorage_pve_snapname_from_parent {
  my ( $parent ) = @_;
  return undef unless length( $parent // '' );
  my $name = $parent;
  $name =~ s/\./-/g;
  return $name;
}

sub purestorage_pg_description_parent {
  my ( $description ) = @_;
  return undef unless defined $description && $description =~ /^PG:\s*([^\s;]+)/;
  return $1;
}

# --- sanitize ---
is( purestorage_pve_snapname_from_parent('pgroup-auto.277'),
  'pgroup-auto-277', 'sanitize pgroup-auto.277' );
is( purestorage_pve_snapname_from_parent('pgroup-auto.mysuffix'),
  'pgroup-auto-mysuffix', 'sanitize custom suffix' );
ok( purestorage_pve_snapname_from_parent('pgroup-auto.277') =~ /^[a-zA-Z][a-zA-Z0-9_-]*$/,
  'sanitized name matches PVE configid charset' );

# --- parent parse from name ---
is(
  purestorage_pgroup_parent_name(
    { name => 'pgroup-auto.277.vm-100-disk-0' },
    'vm-100-disk-0'
  ),
  'pgroup-auto.277',
  'parent from member name'
);
is(
  purestorage_pgroup_parent_name(
    { name => 'pgroup-auto.277.pod::vm-100-disk-0' },
    'pod::vm-100-disk-0'
  ),
  'pgroup-auto.277',
  'parent with pod:: volume source'
);
is(
  purestorage_pgroup_parent_name(
    { name => 'vm-100-disk-0.4166' },
    'vm-100-disk-0'
  ),
  undef,
  'volume-only snap has no pgroup parent'
);
is(
  purestorage_pgroup_parent_name(
    {
      name           => 'pgroup-auto.277.vm-100-disk-0',
      snapshot_group => { name => 'pgroup-auto.277' }
    },
    'vm-100-disk-0'
  ),
  'pgroup-auto.277',
  'prefer snapshot_group.name'
);

# --- PVE UI skip ---
ok(
  purestorage_array_snapshot_is_pve_ui_snapshot(
    { _prefix => '' },
    'vm-100-disk-0',
    { name => 'vm-100-disk-0.snap-daily', suffix => 'snap-daily' }
  ),
  'skip .snap-daily'
);
ok(
  !purestorage_array_snapshot_is_pve_ui_snapshot(
    { _prefix => '' },
    'vm-100-disk-0',
    { name => 'pgroup-auto.277.vm-100-disk-0', suffix => '277.vm-100-disk-0' }
  ),
  'do not skip pgroup member'
);

# --- description parent ---
is( purestorage_pg_description_parent('PG: pgroup-auto.277; vol: snap'),
  'pgroup-auto.277', 'parse PG parent from description' );
is( purestorage_pg_description_parent('user note'), undef, 'non-PG description' );

# --- completeness grouping ---
{
  my %vol_map = (
    'vm-100-disk-0' => { vmid => 100 },
    'vm-100-disk-1' => { vmid => 100 },
  );
  my @vm_vols = sort keys %vol_map;
  my %members_ok = (
    'vm-100-disk-0' => 'pgroup-auto.277.vm-100-disk-0',
    'vm-100-disk-1' => 'pgroup-auto.277.vm-100-disk-1',
  );
  my %members_bad = ( 'vm-100-disk-0' => 'pgroup-auto.277.vm-100-disk-0' );

  my $ok = 1;
  for my $fvn (@vm_vols) {
    unless ( exists $members_ok{$fvn} ) { $ok = 0; last; }
  }
  ok( $ok, 'complete multi-disk group accepted' );

  $ok = 1;
  for my $fvn (@vm_vols) {
    unless ( exists $members_bad{$fvn} ) { $ok = 0; last; }
  }
  ok( !$ok, 'incomplete multi-disk group rejected' );
}

# --- ownership prune scoping ---
{
  my $desc_ours =
    'PG: pgroup-auto.277; vm-100-disk-0: pgroup-auto.277.vm-100-disk-0';
  my $desc_other =
    'PG: pgroup-auto.277; otherstore-vm-100-disk-0: pgroup-auto.277.otherstore-vm-100-disk-0';
  my @vm_vols = ('vm-100-disk-0');

  my $ours = 0;
  for my $fvn (@vm_vols) {
    if ( $desc_ours =~ /(?:^|;\s*)\Q$fvn\E:/ ) { $ours = 1; last; }
  }
  ok( $ours, 'prune ownership matches our volume' );

  $ours = 0;
  for my $fvn (@vm_vols) {
    if ( $desc_other =~ /(?:^|;\s*)\Q$fvn\E:/ ) { $ours = 1; last; }
  }
  ok( !$ours, 'prune ownership ignores other storage volumes' );
}

# --- member name from description ---
{
  my $full_vol = 'vm-100-disk-0';
  my $desc =
    'PG: pgroup-auto.277; vm-100-disk-0: pgroup-auto.277.vm-100-disk-0; vm-100-disk-1: pgroup-auto.277.vm-100-disk-1';
  my $member;
  if ( $desc =~ /(?:^|;\s*)\Q$full_vol\E:\s*([^;]+)/ ) {
    $member = $1;
    $member =~ s/^\s+|\s+$//g;
  }
  is( $member, 'pgroup-auto.277.vm-100-disk-0', 'resolve member from description' );
}

# --- pagination token merge simulation ---
{
  my @pages = (
    { items => [ { name => 'a' } ], continuation_token => 't1' },
    { items => [ { name => 'b' } ], continuation_token => 't2' },
    { items => [ { name => 'c' } ] },
  );
  my @items;
  my $i = 0;
  my $token;
  while (1) {
    my $response = $pages[$i++];
    push @items, @{ $response->{items} // [] };
    $token = $response->{continuation_token};
    last unless length( $token // '' );
  }
  is( scalar @items, 3, 'pagination merges all pages' );
  is( $items[0]{name}, 'a', 'page1 item' );
  is( $items[2]{name}, 'c', 'page3 item' );
}

# --- x-next-token fallback ---
{
  my $content = { items => [] };
  my $next    = 'abc123';
  if ( length($next) && !length( $content->{continuation_token} // '' ) ) {
    $content->{continuation_token} = $next;
  }
  is( $content->{continuation_token}, 'abc123', 'x-next-token fills continuation_token' );
}

# --- PVE name collision fallback ---
{
  my $pve_name  = 'pgroup-auto-277';
  my $snaptime  = 1710000000;
  my %psnaps    = ( $pve_name => { description => 'user snap' } );
  my $final     = $pve_name;
  my $cur       = $psnaps{$pve_name}{description};
  my $ours      = defined( purestorage_pg_description_parent($cur) ) || $cur eq '';
  ok( !$ours, 'user snap is not PG-imported' );
  if ( !$ours ) {
    $final = $pve_name . '-' . $snaptime;
  }
  is( $final, 'pgroup-auto-277-1710000000', 'collision uses snaptime suffix' );
}

# --- volume discovery excludes ephemeral state volumes ---
{
  my $re = qr/^vm-(\d+)-(disk-|cloudinit)/;
  ok( 'vm-100-disk-0' =~ $re,     'discovery matches disk volumes' );
  ok( 'vm-100-cloudinit' =~ $re,  'discovery matches cloudinit volumes' );
  ok( 'vm-100-state-mysnap' !~ $re,
    'discovery no longer matches ephemeral state volumes (would permanently block completeness check)' );
}

# --- source_names chunking for batched snapshot fetch ---
{
  my @vol_names = map { "vm-100-disk-$_" } ( 1 .. 125 );
  my $chunk_size = 50;
  my @chunks;
  for ( my $i = 0; $i < @vol_names; $i += $chunk_size ) {
    my $end = $i + $chunk_size - 1;
    $end = $#vol_names if $end > $#vol_names;
    push @chunks, [ @vol_names[ $i .. $end ] ];
  }
  is( scalar @chunks, 3, 'chunks into 3 batches for 125 volumes at size 50' );
  is( scalar @{ $chunks[0] }, 50, 'first chunk is full size' );
  is( scalar @{ $chunks[2] }, 25, 'last chunk holds the remainder' );
  my @flattened = map { @$_ } @chunks;
  is_deeply( \@flattened, \@vol_names, 'chunking preserves all volumes in order' );
}

# --- LXC container vmids are filtered out of vol_map before syncing ---
{
  my %vol_map = (
    'vm-100-disk-0' => { volname => 'vm-100-disk-0', vmid => 100 },    # QEMU
    'vm-200-disk-0' => { volname => 'vm-200-disk-0', vmid => 200 },    # LXC container
  );
  my %vmid_is_qemu = ( 100 => 1, 200 => 0 );
  for my $name ( keys %vol_map ) {
    delete $vol_map{$name} unless $vmid_is_qemu{ $vol_map{$name}{vmid} };
  }
  ok( exists $vol_map{'vm-100-disk-0'}, 'QEMU vmid volume is kept' );
  ok( !exists $vol_map{'vm-200-disk-0'}, 'LXC container vmid volume is dropped' );
}
