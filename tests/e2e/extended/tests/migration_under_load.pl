#!/usr/bin/perl
use strict;
use warnings;

use POSIX qw(WNOHANG);
use Test::More;

use lib '..';
use lib '.';
use ExtendedGuest qw(use_fio_image reconfigure_guest);
use Proxmox::Test::PVEInstance;
use Proxmox::Test::Util                    qw(skip_unsupported skip_prerequisite guest_name);
use Proxmox::Test::StorageGuest            qw(boot_storage_guest);
use Proxmox::Test::StorageValidation::Util qw(resolve_migration_target_node);

# Extension of the storage plugin validation suite, written the same way: online migration of a guest that
# writes to its data disk the whole time. fio in the guest writes checksummed blocks spread over the disk with
# synchronous direct writes and verifies them at the end; the guest migrates online to another node and back. Per
# migration the disk must stay readable while its multipath map exists, no path may degrade, the target must end
# with as many paths as the source had, the kernels log no disk errors and QEMU on the target has the data disk
# on the volume device. Before every migration fio also writes a large region with plain buffered writes (dirty
# in the cache of the host with cache=writeback). At the end the guest shuts down cleanly, moves to the other
# node and starts there: every acknowledged and every buffered block must be read back from the array.

my $storage_id = $ENV{ PLUGIN_STORAGE_ID };
skip_prerequisite( "no <STORAGE_ID> provided to storage-plugin-validation" ) if !$storage_id;

my $pve    = Proxmox::Test::PVEInstance->new_local();
my $node   = $pve->get_nodename();
my $client = $pve->client();

my $scfg = eval { $client->get( "/storage/$storage_id", {} ) };
skip_prerequisite( "storage '$storage_id' not configured: $@" ) if $@ || !$scfg;
my %content = map { $_ => 1 } split /,/, ( $scfg->{ content } // '' );
skip_prerequisite( "storage '$storage_id' does not support content type 'images'" ) if !$content{ images };
my $shared = $scfg->{ shared } ? 1 : 0;

my ( $target ) = resolve_migration_target_node( $pve );

# Cluster node names are not resolvable by DNS, the cluster knows their addresses.
my %node_address = map { $_->{ name } => $_->{ ip } } grep { ( $_->{ type } // '' ) eq 'node' && $_->{ ip } } @{ $client->get( '/cluster/status', {} ) };
my $serial       = 'LOADTEST';
my $test_started = time();

# The disk must be much larger than the caches on the way (page cache of the host and of the guest, cache of the
# array), or the writes never reach the storage and the result differs from a real workload: the default is twice
# the RAM of this host, at least 20 GiB, at most 512 GiB (thin provisioned on the array, only written blocks count).
my ( $host_ram_kb ) = do {
  open( my $fh, '<', '/proc/meminfo' ) or die "/proc/meminfo: $!\n";
  map { /^MemTotal:\s+(\d+)/ ? $1 : () } <$fh>;
};
my $default_gb = int( $host_ram_kb / 1024 / 1024 ) * 2;
$default_gb = 20  if $default_gb < 20;
$default_gb = 512 if $default_gb > 512;
my $disk_gb = $ENV{ PLUGIN_LOAD_DISK_GB } || $default_gb;

# Guest controller (default virtio-scsi-single) and extra options of the data disk, for example
# cache=writeback,discard=on,iothread=1: set after the first boot, then the guest restarts.
my $scsihw = $ENV{ PLUGIN_LOAD_SCSIHW };

# Data written without sync right before every migration: with cache=writeback it sits dirty in the host cache.
my $dirty_gb     = $ENV{ PLUGIN_LOAD_DIRTY_GB } // 2;
my $disk_options = $ENV{ PLUGIN_LOAD_DISK_OPTIONS };

use_fio_image();

# The writer is a loop of short fio jobs: job N writes 64 MiB of its own region (offset by N) with synchronous direct
# writes at a fixed rate and saves its verify state when it ends (fio saves it only then, not on a signal). The test
# stops the loop when it has what it needs, the loop ends with the current job, and every job is verified.
my $chunk_bytes = 64 * 1024 * 1024;
my $load_iops   = 250;
my $chunk_ios   = $load_iops * 20;

my $vmid = boot_storage_guest(
  $pve,
  storage   => $storage_id,
  name      => guest_name( 'migrateload', $storage_id ),
  data_disk => { size => $disk_gb, serial => $serial },
);
pass( 'booted a guest with a data disk and a responsive agent' );

my $task = sub { return $pve->task_successful( $pve->wait_for_task( $_[0] ) ) };

my $guest_owner = sub {
  my $resources = $client->get( '/cluster/resources', { type => 'vm' } );
  my ( $guest ) = grep { ( $_->{ type } // '' ) eq 'qemu' && ( $_->{ vmid } // 0 ) == $vmid } @$resources;
  return $guest ? $guest->{ node } : undef;
};

my $cleanup = sub {
  my $gone = eval {
    my $owner = $guest_owner->();
    die "could not destroy guest $vmid on '$owner'\n"
      if defined( $owner ) && !$pve->destroy_guest_on( $owner, qemu => $vmid );
    1;
  };
  diag( "guest cleanup failed: $@" ) if !$gone;
  return $gone;
};

if ( ( $scsihw && $scsihw ne 'virtio-scsi-single' ) || $disk_options ) {
  my $reconfigured = reconfigure_guest( $pve, $vmid, scsihw => $scsihw, disk_options => $disk_options );
  diag( "could not apply the guest options: $@" ) if !$reconfigured;
  ok( $reconfigured, 'the guest runs with controller ' . ( $scsihw // 'default' ) . " and data disk options '" . ( $disk_options // '' ) . "'" )
    or do { $cleanup->(); done_testing(); exit 1 };
}

# A command on a cluster node: locally for this one, over the root ssh trust of the cluster for the others.
# The command goes to the shell as one argument, so its own quotes need no escaping. The known_hosts of the
# cluster may lack a peer, so a key seen for the first time is accepted and a changed one is still refused.
my $on_node = sub {
  my ( $n, $cmd ) = @_;
  my @argv =
    $n eq $node
    ? ( 'timeout', 30, 'sh', '-c', $cmd )
    : (
      'timeout', 30, 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o',
      'StrictHostKeyChecking=accept-new',
      "root\@" . ( $node_address{ $n } // $n ), $cmd
    );
  open( my $out, '-|', @argv ) or return "could not run @argv: $!";
  my $text = do { local $/; <$out> }
    // '';
  close $out;
  return $text;
};

my $guest_sh = sub {
  my ( $n, $script ) = @_;
  return $pve->qga_exec_on( $n, $vmid, '/bin/sh', '-c', $script );
};

my $dev_cmd = qq{lsblk -dnp -o NAME,SERIAL | awk '\$2=="$serial"{print \$1; exit}'};

# The device of the data disk and the regions on it: the writer uses the first nine tenths, the buffered bulk write
# the last tenth (at most PLUGIN_LOAD_DIRTY_GB). One line, the guest agent of PVE 8 turns line breaks into CRLF.
my $prelude =
    q{dev=$(}
  . $dev_cmd
  . q{); size=$(blockdev --getsize64 "$dev"); wsize=$((size / 10 * 9)); bytes=$((}
  . $dirty_gb
  . q{ * 1073741824)); [ $bytes -gt $((size / 10)) ] && bytes=$((size / 10)); boff=$(( (size - bytes) / 1048576 * 1048576 )); export dev wsize bytes boff; };
my $fio_common = q{--ioengine=psync --aux-path=/var/tmp/fio-state --filename="$dev"};
my $fio_load =
qq{fio --name=load\$j $fio_common --rw=randwrite --bs=4k --offset=\$((j * $chunk_bytes)) --size=$chunk_bytes --direct=1 --sync=1 --verify=sha256 --randseed=7 --norandommap --number_ios=$chunk_ios --rate_iops=$load_iops};
my $fio_bulk = qq{fio --name=bulk $fio_common --rw=write --bs=1m --size=\$bytes --offset=\$boff --verify=crc32c};

# How many jobs of the writer have started: it grows while the writer works.
my $written = sub {
  my ( $n ) = @_;
  my $r = $guest_sh->( $n, 'cat /var/tmp/fio-load.progress 2>/dev/null' );
  return $r->{ out } =~ /^(\d+)/ ? $1 + 0 : 0;
};

# Runs a shell script of the guest in the background (a guest agent command is cut after 300 seconds), polls its exit
# code and returns it with the first error lines of the fio outputs; on a timeout the progress fio reported is the
# evidence.
my $guest_job = sub {
  my ( $n, $script, $tag, $limit ) = @_;
  $limit //= 900;
  $guest_sh->( $n, "$prelude rm -f /var/tmp/$tag.rc; (nohup sh -c '$script; echo \$? >/var/tmp/$tag.rc' >/dev/null 2>&1 &)" );
  for ( 1 .. $limit / 5 ) {
    my $r = $guest_sh->( $n, "cat /var/tmp/$tag.rc 2>/dev/null" );
    return ( $1, $guest_sh->( $n, "grep -hE 'error|bad |mismatch' /var/tmp/$tag*.out 2>/dev/null | head -n 3" )->{ out } ) if $r->{ out } =~ /^(\d+)/;
    sleep 5;
  }
  return ( 'timeout after ' . $limit . ' s', $guest_sh->( $n, "tail -n 6 /var/tmp/$tag*.out 2>/dev/null" )->{ out } );
};

# One fio command (bulk write or its verification) as a job of the guest.
my $fio = sub {
  my ( $n, $command, $tag ) = @_;
  return $guest_job->( $n, "$command --output=/var/tmp/$tag.out --status-interval=10", $tag );
};

# Stops the writer loop (it ends with the current job) and returns how many jobs it ran.
my $stop_writer = sub {
  my ( $n ) = @_;
  $guest_sh->( $n, 'touch /var/tmp/fio-stop' );
  for ( 1 .. 24 ) {
    my $r = $guest_sh->( $n, 'cat /var/tmp/fio-load.chunks 2>/dev/null' );
    return $1 + 0 if $r->{ out } =~ /^(\d+)/;
    sleep 5;
  }
  return 0;
};

# Verifies every job of the writer, from its saved state.
my $verify_writer = sub {
  my ( $n ) = @_;
  return $guest_job->(
    $n,
    'n=$(cat /var/tmp/fio-load.chunks); j=0; rc=0; while [ $j -lt $n ]; do '
      . $fio_load
      . ' --verify_only --do_verify=1 --verify_state_load=1 --output=/var/tmp/fio-loadv$j.out || rc=1; j=$((j + 1)); done; [ $rc -eq 0 ]',
    'fio-loadv'
  );
};

# Paths of the multipath map of a volume as `multipath -ll` lists them, and whether the device reads.
my $sample = sub {
  my ( $n, $wwid, $path ) = @_;
  my $out =
    $on_node->( $n, "timeout 5 multipath -ll $wwid 2>&1; timeout 5 dd if=$path of=/dev/null bs=4096 count=1 iflag=direct >/dev/null 2>&1; echo RC=\$?" );
  my @paths = $out =~ /^[\s|`\-+]*\d+:\d+:\d+:\d+\s+(\S+)\s+\d+:\d+\s+(\S+)\s+(\S+)\s+(\S+)\s*$/mg;
  my ( @bad, $count );
  while ( my ( $dev, $dm, $check, $state ) = splice( @paths, 0, 4 ) ) {
    $count++;
    push @bad, "$dev $dm $check $state" if $dm eq 'failed' || $check =~ /^(faulty|shaky)$/ || $state eq 'offline';
  }
  my ( $rc ) = $out =~ /RC=(\d+)\s*\z/;
  return { node => $n, paths => $count // 0, bad => \@bad, readable => ( defined $rc && $rc == 0 ) ? 1 : 0 };
};

my $kernel_errors = sub {
  my ( $n, $since ) = @_;
  my $log = $on_node->( $n, "journalctl -k --since \@$since --no-pager 2>&1" );
  return grep {
    /(?i:I\/O error|Buffer I\/O|\bpath failed\b|rejecting I\/O|device-mapper: multipath: Failing path|timing out command|Medium Error)|\bFAILED Result\b/
  } split /\n/, $log;
};

# Lines the plugin logs when a removal or an activation did not go cleanly.
my $plugin_problems = sub {
  my ( $n, $since ) = @_;
  my $log = $on_node->(
    $n, "journalctl --since \@$since --no-pager 2>&1 | grep -E 'Cannot execute|Kernel refused|still present after|Timeout while waiting|map in use'"
  );
  return grep { length } split /\n/, $log;
};

my $drive_path = sub {
  my ( $n, $drive ) = @_;
  my $out = $on_node->( $n, "printf 'info block\\n' | qm monitor $vmid 2>&1" );
  return $out =~ /^drive-\Q$drive\E \([^)]*\): (\S+)/m ? $1 : undef;
};

# Migrates and samples both nodes once a second meanwhile; returns the problems found.
my $migrate = sub {
  my ( $from, $to, $wwid, $path, $baseline ) = @_;
  my $params = { target => $to, online => 1 };
  $params->{ 'with-local-disks' } = 1 if !$shared;
  my $since = time();

  my $dir = "/tmp/migrateload-$$";
  mkdir $dir;
  my $pid = fork() // die "fork: $!\n";
  if ( !$pid ) {
    my $i = 0;
    while ( 1 ) {
      for my $n ( $from, $to ) {
        my $s = $sample->( $n, $wwid, $path );
        open( my $fh, '>>', "$dir/samples" ) or exit 1;
        print { $fh } join( ' ', $n, $s->{ paths }, $s->{ readable }, scalar( @{ $s->{ bad } } ), join( ',', map { s/ /_/gr } @{ $s->{ bad } } ) ), "\n";
      }
      sleep 1;
    }
  }
  my $upid  = eval         { $client->post( "/nodes/$from/qemu/$vmid/migrate", $params ) };
  my $task  = $upid ? eval { $pve->wait_for_task( $upid ) } : undef;
  my $error = $@;
  kill 'TERM', $pid;
  waitpid( $pid, 0 );

  my @problems;
  push @problems, "migration $from to $to failed: " . ( $error || $task // 'unknown' ) if $error || !$pve->task_successful( $task );

  # a task that ends OK can still log a warning of Perl, of Proxmox or of the plugin: that is a problem too
  my $log = $upid ? eval { $client->get( "/nodes/$from/tasks/$upid/log" ) } : undef;
  push @problems, "migration $from to $to logged: $_->{ t }"
    for grep { $_->{ t } =~ /Use of uninitialized|\bWARN\b|\bERROR\b|Timeout while waiting|still present/ } @{ $log // [] };
  my $samples = 0;
  if ( open( my $fh, '<', "$dir/samples" ) ) {
    while ( <$fh> ) {
      my ( $n, $paths, $readable, $nbad, $bad ) = split ' ';
      $samples++;
      push @problems, "$n: device not readable while its multipath map exists" if $paths && !$readable;
      push @problems, "$n: degraded path: $bad"                                if $nbad;
    }
    close $fh;
  }
  unlink "$dir/samples";
  rmdir $dir;
  my $after = $sample->( $to, $wwid, $path );
  push @problems, "$to: $after->{paths} paths after migration, baseline $baseline" if $after->{ paths } != $baseline;
  my $left = $sample->( $from, $wwid, $path );
  push @problems, "$from: multipath map still exists after migration" if $left->{ paths };
  push @problems, map { "$_" } ( $kernel_errors->( $from, $since ), $kernel_errors->( $to, $since ) );
  return ( $samples, @problems );
};

my $volume_wwn;
eval {
  my $version = $guest_sh->( $node, 'fio --version' );
  like( $version->{ out }, qr/^fio-/, "fio is in the guest ($version->{out})" ) or skip_prerequisite( 'no fio in the guest image' );
  my $loop =
      q{j=0; while [ ! -e /var/tmp/fio-stop ] && [ $((j * }
    . $chunk_bytes
    . q{)) -lt $wsize ]; do echo $j >/var/tmp/fio-load.progress; }
    . $fio_load
    . q{ --output=/var/tmp/fio-load$j.out || echo $? >/var/tmp/fio-load.rc; j=$((j + 1)); done; echo $j >/var/tmp/fio-load.chunks};
  my $r = $guest_sh->(
    $node,
"$prelude mkdir -p /var/tmp/fio-state; rm -f /var/tmp/fio-stop /var/tmp/fio-load.rc /var/tmp/fio-load.chunks /var/tmp/fio-load.progress /var/tmp/fio-state/*; (nohup sh -c '$loop' >/dev/null 2>&1 &)"
  );
  is( $r->{ exitcode }, 0, 'the writer started on the data disk' );

  my $started = 0;
  for ( 1 .. 60 ) { $started = $written->( $node ); last if $started >= 1; sleep 2; }
  ok( $started >= 1, "the writer works (job $started)" );

  my $config = $client->get( "/nodes/$node/qemu/$vmid/config", {} );
  my ( $volid ) = $config->{ scsi1 } =~ /^([^,]+)/;
  chomp( my $path = qx{pvesm path '$volid' 2>/dev/null} );
  my ( $wwn ) = $path =~ /wwn-0x([0-9a-f]{32})/;
  skip_prerequisite( "the data disk has no wwn device path: '$path'" ) if !$wwn;
  my $wwid = "3$wwn";
  $volume_wwn = $wwn;
  my $baseline = $sample->( $node, $wwid, $path )->{ paths };
  ok( $baseline >= 1, "the data disk has $baseline multipath paths on '$node'" );

  my $owner = $node;
  for my $leg ( [ $node, $target ], [ $target, $node ] ) {
    my ( $from, $to ) = @$leg;
    if ( $dirty_gb ) {
      my ( $rc, $out ) = $fio->( $from, "$fio_bulk --direct=0", 'fio-bulk' );
      is( $rc, 0, "bulk data written without sync before the migration '$from' to '$to'" ) or diag( $out );
    }
    my $before = $written->( $from );
    my ( $samples, @problems ) = $migrate->( $from, $to, $wwid, $path, $baseline );
    $owner = $guest_owner->() // 'unknown';
    is( $owner, $to, "the guest is on '$to' after the online migration" );
    is_deeply( \@problems, [], "the disk stayed healthy during the migration '$from' to '$to' ($samples samples)" ) or diag( join "\n", @problems );
    is( $drive_path->( $to, 'scsi1' ), $path, "QEMU on '$to' has the data disk on the volume device" );
    my $now = 0;
    for ( 1 .. 60 ) { $now = $written->( $to ); last if $now > $before; sleep 2; }
    ok( $now > $before, "the guest keeps writing on '$to': job $before before the migration, job $now after" );
    is_deeply( [ $kernel_errors->( $to, time() - 60 ) ], [], "no disk errors in the kernel log of '$to'" );
  }

  my $chunks = $stop_writer->( $owner );
  ok( $chunks >= 2, "the writer ran $chunks jobs and stopped" );
  is( $guest_sh->( $owner, 'cat /var/tmp/fio-load.rc 2>/dev/null' )->{ out }, '', 'no job of the writer failed' );
  my ( $rc, $out ) = $verify_writer->( $owner );
  is( $rc, 0, "every acknowledged block of the $chunks writer jobs is on the disk after both migrations" ) or diag( $out );
  if ( $dirty_gb ) {
    ( $rc, $out ) = $fio->( $owner, "$fio_bulk --direct=1 --verify_only --do_verify=1 --verify_state_load=1", 'fio-bulkv' );
    is( $rc, 0, 'the bulk data written without sync is on the disk after both migrations' ) or diag( $out );
  }

  # A clean shutdown with data still unsynced, then a cold start on the other node: what the guest wrote must have
  # reached the array and be readable from another host, and the volume must leave the first node without a trace.
  if ( $dirty_gb ) {
    ( $rc, $out ) = $fio->( $owner, "$fio_bulk --direct=0", 'fio-bulk' );
    is( $rc, 0, 'bulk data written without sync right before the shutdown' ) or diag( $out );
  }
  my $first = $owner;
  my $other = $first eq $node ? $target : $node;
  ok( eval { $task->( $client->post( "/nodes/$first/qemu/$vmid/status/shutdown", { timeout => 180 } ) ) }, "the guest shut down cleanly on '$first'" )
    or diag( $@ );
  my $move = { target => $other };
  $move->{ 'with-local-disks' } = 1 if !$shared;
  ok( eval { $task->( $client->post( "/nodes/$first/qemu/$vmid/migrate",      $move ) ) }, "the stopped guest moved to '$other'" ) or diag( $@ );
  ok( eval { $task->( $client->post( "/nodes/$other/qemu/$vmid/status/start", {} ) ) } && $pve->wait_for_qga_on( $other, $vmid, 240 ),
    "the guest started on '$other' and its agent answers" )
    or diag( $@ );
  ( $rc, $out ) = $verify_writer->( $other );
  is( $rc, 0, "every acknowledged block is on the array, read after the cold start on '$other'" ) or diag( $out );

  if ( $dirty_gb ) {
    ( $rc, $out ) = $fio->( $other, "$fio_bulk --direct=1 --verify_only --do_verify=1 --verify_state_load=1", 'fio-bulkv' );
    is( $rc, 0, "the bulk data written without sync is on the array after the shutdown, read on '$other'" ) or diag( $out );
  }
  1;
} or fail( "migration under load test failed: $@" );

ok( $cleanup->(), 'guest destroyed' );

# Nothing of the volume may stay on any node: a path left behind fails once the array disconnects the volume.
if ( defined $volume_wwn ) {
  for my $n ( $node, $target ) {
    my $left = $on_node->( $n, "grep -l 'naa.$volume_wwn' /sys/block/sd*/device/wwid 2>/dev/null" );
    is( $left, '', "no SCSI device of the data disk is left on '$n' after the guest is destroyed" );
  }
}

# The removal flushes and releases the volume without a refusal to retry, a path to delete or a timeout.
for my $n ( $node, $target ) {
  is_deeply( [ $plugin_problems->( $n, $test_started ) ], [], "the plugin logged no removal or activation problems on '$n'" )
    or diag( join "\n", $plugin_problems->( $n, $test_started ) );
}

done_testing();
