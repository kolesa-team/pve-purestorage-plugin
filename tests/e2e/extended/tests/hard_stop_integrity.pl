#!/usr/bin/perl
use strict;
use warnings;

use Test::More;

use lib '..';
use lib '.';
use ExtendedGuest qw(use_fio_image reconfigure_guest guest_data_device);
use Proxmox::Test::PVEInstance;
use Proxmox::Test::Util qw(skip_prerequisite guest_name);
use Proxmox::Test::StorageGuest qw(boot_storage_guest);

# Extension of the storage plugin validation suite, written the same way: the guest is stopped the hard way (qm stop
# kills QEMU, no shutdown) while it writes. With cache=writeback on the data disk QEMU holds data in the cache of the
# host until the guest flushes. What the guest has been told is written (fio with direct, synchronous writes, jobs that
# ended) must be on the array after the stop and a cold start; data that was only buffered or still being written when
# QEMU died may be lost, and is not checked.

my $storage_id = $ENV{PLUGIN_STORAGE_ID};
skip_prerequisite("no <STORAGE_ID> provided to storage-plugin-validation") if !$storage_id;

my $pve = Proxmox::Test::PVEInstance->new_local();
my $node = $pve->get_nodename();
my $client = $pve->client();
my $scfg = eval { $client->get("/storage/$storage_id", {}) };
skip_prerequisite("storage '$storage_id' not configured: $@") if $@ || !$scfg;
skip_prerequisite("storage '$storage_id' does not support content type 'images'") if ($scfg->{content} // '') !~ /\bimages\b/;

use_fio_image();
my $serial = 'HARDSTOP';
my $started = time();
my $jobs = 3;
my $chunk = 64 * 1024 * 1024;
my $task = sub { return $pve->task_successful($pve->wait_for_task($_[0])) };
my $dev = guest_data_device($serial);
my $fio = sub {
    my ($j) = @_;
    my $offset = $j * $chunk;
    return qq{fio --name=job$j --ioengine=psync --aux-path=/var/tmp/fio-state --filename="\$dev" --rw=randwrite --bs=4k --offset=$offset --size=$chunk --direct=1 --sync=1 --verify=sha256 --randseed=7 --norandommap --number_ios=2000};
};

my $vmid = boot_storage_guest($pve, storage => $storage_id, name => guest_name('hardstop', $storage_id), data_disk => { size => 2, serial => $serial });
pass('booted a guest with a data disk and a responsive agent');

my $wwn;
eval {
    ok(reconfigure_guest($pve, $vmid, disk_options => 'cache=writeback,discard=on,iothread=1'), 'the guest runs with cache=writeback on the data disk') or die "no guest\n";
    my $config = $client->get("/nodes/$node/qemu/$vmid/config", {});
    my ($volid) = $config->{scsi1} =~ /^([^,]+)/;
    chomp(my $path = qx{pvesm path '$volid' 2>/dev/null});
    ($wwn) = $path =~ /wwn-0x([0-9a-f]{32})/;

    # jobs that end: their blocks were acknowledged, their verify state is saved, the state files are synced
    my $script = join(' ', 'dev=$(' . $dev . ');', 'mkdir -p /var/tmp/fio-state; rm -f /var/tmp/fio-state/*;', (map { $fio->($_) . ' --output=/var/tmp/fio-w' . $_ . '.out || exit 1;' } 0 .. $jobs - 1), 'sync; echo done');
    my $w = $pve->qga_exec($vmid, '/bin/sh', '-c', $script);
    like($w->{out}, qr/done/, "$jobs jobs of synchronous direct writes ended") or die "$w->{out}$w->{err}\n";

    # still running when QEMU dies: one more job and a buffered write that nothing flushes
    my $busy = 'dev=$(' . $dev . '); (nohup sh -c \'' . $fio->($jobs) . ' --rate_iops=100 --output=/var/tmp/fio-w' . $jobs . '.out; true\' >/dev/null 2>&1 &); (nohup dd if=/dev/zero of="$dev" bs=1M count=512 seek=1024 >/dev/null 2>&1 &); sleep 3; echo started';
    like($pve->qga_exec($vmid, '/bin/sh', '-c', $busy)->{out}, qr/started/, 'a job and a buffered write are running');

    ok(eval { $task->($client->post("/nodes/$node/qemu/$vmid/status/stop", {})) }, 'the guest is stopped the hard way') or diag($@);
    ok(eval { $task->($client->post("/nodes/$node/qemu/$vmid/status/start", {})) } && $pve->wait_for_qga($vmid, 240), 'the guest starts again and its agent answers') or diag($@);

    my $verify = join(' ', 'dev=$(' . $dev . ');', 'rc=0;', (map { $fio->($_) . ' --verify_only --do_verify=1 --verify_state_load=1 --output=/var/tmp/fio-v' . $_ . '.out || rc=1;' } 0 .. $jobs - 1), 'echo rc=$rc');
    my $v = $pve->qga_exec($vmid, '/bin/sh', '-c', $verify);
    like($v->{out}, qr/rc=0/, "every block of the $jobs ended jobs reads back after the hard stop") or diag("$v->{out}$v->{err}");
    1;
} or fail("hard stop test failed: $@");

ok($pve->destroy_guest(qemu => $vmid), 'guest destroyed');
if ($wwn) {
    my $left = `grep -l 'naa.$wwn' /sys/block/sd*/device/wwid 2>/dev/null`;
    is($left, '', "no SCSI device of the data disk is left on '$node'");
}
my $log = `journalctl --since \@$started --no-pager 2>&1 | grep -E 'Cannot execute|Kernel refused|still present after|Timeout while waiting|map in use'`;
is($log, '', "the plugin logged no removal or activation problems on '$node'") or diag($log);

done_testing();
