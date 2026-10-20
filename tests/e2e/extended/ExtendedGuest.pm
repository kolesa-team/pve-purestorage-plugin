package ExtendedGuest;
use strict;
use warnings;

use Exporter 'import';
use Fcntl qw(O_WRONLY O_CREAT O_TRUNC);
use Proxmox::Test::StorageGuest;
use Proxmox::Test::Util qw(skip_prerequisite);

our @EXPORT_OK = qw(use_fio_image reconfigure_guest guest_data_device);

# Helpers of the extended tests that run a guest with fio in it.

# fio is not in the prepared image of the suite (the guest agent only), so one more image with fio is made from it the
# same way (virt-customize, cached beside it), unless PLUGIN_QGA_IMAGE names an image of the caller. Call it before
# boot_storage_guest, which reads PLUGIN_QGA_IMAGE.
sub use_fio_image {
    return if $ENV{PLUGIN_QGA_IMAGE};
    my $base = Proxmox::Test::StorageGuest::prepared_guest_image();
    (my $image = $base) =~ s/\.qcow2$/-fio.qcow2/;
    if (!-f $image) {
        my $tmp = "$image.part";
        unlink $tmp;
        # PLUGIN_GUEST_PASSWORD sets the root password for a login on the console; it goes through a file of mode 600,
        # not through the command line. It is baked in when the image is built: delete the image to change it.
        my @password;
        my $password_file = "$image.password";
        if (length($ENV{PLUGIN_GUEST_PASSWORD} // '')) {
            sysopen(my $fh, $password_file, O_WRONLY | O_CREAT | O_TRUNC, 0600) or skip_prerequisite("cannot write $password_file: $!");
            print {$fh} $ENV{PLUGIN_GUEST_PASSWORD};
            close $fh;
            @password = ('--root-password', "file:$password_file");
        }
        my $built = system('cp', '--reflink=auto', $base, $tmp) == 0 && system('virt-customize', '-q', '-a', $tmp, '--install', 'fio', @password) == 0;
        unlink $password_file;
        $built or do { unlink $tmp; skip_prerequisite('could not prepare a guest image with fio') };
        rename($tmp, $image) or skip_prerequisite('could not store the guest image with fio');
    }
    $ENV{PLUGIN_QGA_IMAGE} = $image;
}

# Stops the guest, sets the controller and/or extra options of its data disk (scsi1) and starts it again. Returns true
# when the guest agent answers.
sub reconfigure_guest {
    my ($pve, $vmid, %opts) = @_;
    my $node = $pve->get_nodename();
    my $client = $pve->client();
    my $task = sub { return $pve->task_successful($pve->wait_for_task($_[0])) };
    my $done = eval {
        $task->($client->post("/nodes/$node/qemu/$vmid/status/stop", {})) or die "could not stop the guest\n";
        my $config = $client->get("/nodes/$node/qemu/$vmid/config", {});
        my %change;
        $change{scsihw} = $opts{scsihw} if $opts{scsihw};
        $change{scsi1} = "$config->{scsi1}," . $opts{disk_options} if $opts{disk_options};
        $client->put("/nodes/$node/qemu/$vmid/config", \%change);
        $task->($client->post("/nodes/$node/qemu/$vmid/status/start", {})) or die "could not start the guest\n";
        $pve->wait_for_qga($vmid, 240) or die "the guest agent did not come up\n";
        1;
    };
    warn "reconfigure_guest: $@" if !$done;
    return $done;
}

# The shell command that prints the device of the data disk with the given serial in the guest.
sub guest_data_device {
    my ($serial) = @_;
    return qq{lsblk -dnp -o NAME,SERIAL | awk '\$2=="$serial"{print \$1; exit}'};
}

1;
