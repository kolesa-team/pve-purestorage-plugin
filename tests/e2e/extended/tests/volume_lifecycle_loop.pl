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

# Extension of the storage plugin validation suite, written the same way: the life of a volume repeated in a loop.
# Every round boots a guest with a new data disk, writes checksummed blocks into it, verifies them, destroys the
# guest and checks that nothing of the volume is left on the node. The next round gets a new volume on the LUN
# number the array has just freed, which is where a path left behind by the last round would make the mapping fail.
# Every round uses another controller of the guest (virtio-scsi-single, virtio-scsi-pci): the plugin must not care.

my $storage_id = $ENV{PLUGIN_STORAGE_ID};
skip_prerequisite("no <STORAGE_ID> provided to storage-plugin-validation") if !$storage_id;

my $pve = Proxmox::Test::PVEInstance->new_local();
my $node = $pve->get_nodename();
my $client = $pve->client();
my $scfg = eval { $client->get("/storage/$storage_id", {}) };
skip_prerequisite("storage '$storage_id' not configured: $@") if $@ || !$scfg;
skip_prerequisite("storage '$storage_id' does not support content type 'images'") if ($scfg->{content} // '') !~ /\bimages\b/;

# lsi is left out: the cloud kernel of the guest image has no driver for it (no sym53c8xx module), so the guest cannot find its boot disk
my @controllers = qw(virtio-scsi-single virtio-scsi-pci);
use_fio_image();
my $rounds = $ENV{PLUGIN_LIFECYCLE_ROUNDS} || @controllers;
my $serial = 'LIFECYCLE';
my $started = time();
my $fio = q{fio --name=w --ioengine=psync --aux-path=/var/tmp/fio-state --rw=randwrite --bs=4k --size=64m --direct=1 --sync=1 --verify=sha256 --randseed=3 --number_ios=2000};

for my $round (1 .. $rounds) {
    my $scsihw = $controllers[($round - 1) % @controllers];
    my $vmid = boot_storage_guest($pve, storage => $storage_id, name => guest_name('lifecycle', $storage_id), data_disk => { size => 2, serial => $serial });
    my $ready = $scsihw eq 'virtio-scsi-single' || reconfigure_guest($pve, $vmid, scsihw => $scsihw);
    ok($ready, "round $round: the guest runs with controller $scsihw");
    my ($wwn, $volid);
    if ($ready) {
        my $config = $client->get("/nodes/$node/qemu/$vmid/config", {});
        ($volid) = $config->{scsi1} =~ /^([^,]+)/;
        chomp(my $path = qx{pvesm path '$volid' 2>/dev/null});
        ($wwn) = $path =~ /wwn-0x([0-9a-f]{32})/;

        my $dev = guest_data_device($serial);
        my $write = $pve->qga_exec($vmid, '/bin/sh', '-c', "mkdir -p /var/tmp/fio-state; dev=\$($dev); $fio --filename=\"\$dev\" --output=/var/tmp/fio-w.out; echo rc=\$?");
        like($write->{out}, qr/rc=0/, "round $round: blocks written with synchronous direct writes") or diag("$write->{out}$write->{err}");
        my $verify = $pve->qga_exec($vmid, '/bin/sh', '-c', "dev=\$($dev); $fio --filename=\"\$dev\" --verify_only --do_verify=1 --verify_state_load=1 --output=/var/tmp/fio-v.out; echo rc=\$?");
        like($verify->{out}, qr/rc=0/, "round $round: every written block reads back") or diag("$verify->{out}$verify->{err}");
    }

    ok($pve->destroy_guest(qemu => $vmid), "round $round: guest destroyed");
    if ($wwn) {
        my $left = `grep -l 'naa.$wwn' /sys/block/sd*/device/wwid 2>/dev/null`;
        is($left, '', "round $round: no SCSI device of the volume is left on '$node'");
    }
}

my $log = `journalctl --since \@$started --no-pager 2>&1 | grep -E 'Cannot execute|Kernel refused|still present after|Timeout while waiting|map in use'`;
is($log, '', "the plugin logged no removal or activation problems on '$node'") or diag($log);

done_testing();
