#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

# The whole protection-group sync of one storage against a scripted array and a fake PVE::QemuConfig: what ends up in
# the configs of the VMs of the node, for QEMU VMs, containers, new and vanished snapshots, and an array that answers
# only in part.

{

  package PVE::QemuConfig;
  our ( %CONF, %LOAD, $LOCKED );

  sub config_file { return $CONF{ $_[1] } ? $0 : '/nonexistent' }

  sub load_config {
    my ( $class, $vmid ) = @_;
    $LOAD{ $vmid }++;
    die "Configuration file for $vmid does not exist\n" if !$CONF{ $vmid };
    return $CONF{ $vmid };
  }
  sub lock_config { my ( $class, $vmid, $code ) = @_; local $LOCKED = $vmid; return $code->() }
  sub write_config { my ( $class, $vmid, $conf ) = @_; $CONF{ $vmid } = $conf }
  $INC{ 'PVE/QemuConfig.pm' } = 1;
}

my $plugin = PluginLoader::load();
my $pkg    = 'PVE::Storage::Custom::PureStoragePlugin';
my $sync   = $plugin->can( 'purestorage_sync_array_snapshots' ) // BAIL_OUT( 'no purestorage_sync_array_snapshots' );

my ( %array, @calls );
{
  no warnings 'redefine';
  no strict 'refs';
  *{ "${pkg}::purestorage_api_list" } = sub {
    my ( $scfg, $action ) = @_;
    push @calls, $action->{ type };
    my $answer = $array{ $action->{ type } };
    die "array does not answer\n" if !$answer;
    return $answer;
  };
}

my $scfg = { vgname => 'vg' };

sub reset_stand {
  %PVE::QemuConfig::CONF = %PVE::QemuConfig::LOAD = ();
  @calls                 = ();
  %array                 = (
    volumes                      => { items => [ map { { name => "vg/vm-$_-disk-0" } } 100,                                               200 ] },
    'volume-snapshots'           => { items => [ map { { name => "pg.1.vg/vm-$_-disk-0", source => { name => "vg/vm-$_-disk-0" } } } 100, 200 ] },
    'protection-group-snapshots' => { items => [ { name => 'pg.1', created => 1710000000000 } ] },
  );
  $PVE::QemuConfig::CONF{ 100 } = { scsi0 => 'pure:vm-100-disk-0,size=1G', snapshots => {} };    # a VM of this node
}

# --- a group snapshot is imported into the VM of the node; a container and a VM of another node are left alone ---
reset_stand();
$sync->( $scfg, 'pure' );
my $snaps = $PVE::QemuConfig::CONF{ 100 }{ snapshots };
is_deeply( [ sort keys %$snaps ], ['pg-1'], 'the snapshot is imported under its sanitized name' );
is( $snaps->{ 'pg-1' }{ snaptime }, 1710000000, 'with the time of the group snapshot' );
like( $snaps->{ 'pg-1' }{ description }, qr/^PG: pg\.1; /, 'and a description that names the group' );
ok( !exists $PVE::QemuConfig::CONF{ 200 }, 'a VM that is not on this node gets no config' );
is( $PVE::QemuConfig::LOAD{ 100 }, 1, 'the config of the VM is read once in a cycle' );

# --- the second cycle changes nothing ---
my $before = $PVE::QemuConfig::CONF{ 100 };
$sync->( $scfg, 'pure' );
is_deeply( [ sort keys %{ $PVE::QemuConfig::CONF{ 100 }{ snapshots } } ], ['pg-1'], 'a second cycle keeps the entry' );

# --- the snapshot vanished from the array: the entry goes ---
$array{ 'protection-group-snapshots' } = { items => [] };
$array{ 'volume-snapshots' }           = { items => [] };
$sync->( $scfg, 'pure' );
is_deeply( [ keys %{ $PVE::QemuConfig::CONF{ 100 }{ snapshots } } ], [], 'an entry whose snapshot is gone from the array is removed' );

# --- the answer is partial: nothing is removed ---
reset_stand();
$sync->( $scfg, 'pure' );
$array{ 'protection-group-snapshots' } = { items => [], truncated => 1 };
$array{ 'volume-snapshots' }           = { items => [] };
$sync->( $scfg, 'pure' );
is_deeply( [ keys %{ $PVE::QemuConfig::CONF{ 100 }{ snapshots } } ], ['pg-1'], 'with an incomplete answer no entry is removed' );

# --- no answer for the list of volumes: nothing happens ---
reset_stand();
delete $array{ volumes };
$sync->( $scfg, 'pure' );
is_deeply( [ keys %{ $PVE::QemuConfig::CONF{ 100 }{ snapshots } } ], [], 'without a list of volumes nothing is imported' );

# --- a group that sorts earlier and gives the same name appears in a later cycle: the entry stays with its group ---
reset_stand();
my $group_snap = sub { return { name => "$_[0].vg/vm-100-disk-0", source => { name => 'vg/vm-100-disk-0' } } };
$array{ 'volume-snapshots' }           = { items => [ $group_snap->( 'a.b-c' ) ] };
$array{ 'protection-group-snapshots' } = { items => [ { name => 'a.b-c', created => 1710000000000 } ] };
$sync->( $scfg, 'pure' );
$array{ 'volume-snapshots' }           = { items => [ $group_snap->( 'a.b-c' ), $group_snap->( 'a-b.c' ) ] };
$array{ 'protection-group-snapshots' } = { items => [ { name => 'a.b-c', created => 1710000000000 }, { name => 'a-b.c', created => 1710003600000 } ] };
$sync->( $scfg, 'pure' );
$snaps = $PVE::QemuConfig::CONF{ 100 }{ snapshots };
like( $snaps->{ 'a-b-c' }{ description }, qr/^PG: a\.b-c;/, 'the entry keeps the group it was imported for' );
is( $snaps->{ 'a-b-c' }{ snaptime }, 1710000000, 'and its time' );
like( $snaps->{ 'a-b-c-20240309-170000' }{ description } // '', qr/^PG: a-b\.c;/, 'the new group gets the name with the time of its snapshot' );

done_testing;
