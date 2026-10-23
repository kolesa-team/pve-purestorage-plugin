# Prerequisites and installation

## Prerequisites

Before installing and using this plugin, ensure that your Proxmox VE environment meets the following prerequisites.

### Multipath Configuration

To ensure correct operation with Pure Storage, you need to configure your multipath settings appropriately. Specifically, you need to set find_multipaths to no in your multipath.conf file. This setting disables the automatic detection of multipath devices, which is necessary for Pure Storage devices to be correctly recognized.

Below is an example of how your multipath.conf file should look when configured for Pure Storage arrays:

```text
defaults {
  polling_interval 5    # how often the paths are checked, in seconds
  find_multipaths no
}

devices {
  device {
    vendor               "PURE"
    product              "FlashArray"
    path_selector        "queue-length 0"
    hardware_handler     "1 alua"
    path_grouping_policy group_by_prio
    prio                 alua
    failback             immediate
    path_checker         tur
    fast_io_fail_tmo     10
    user_friendly_names  no
    no_path_retry        60   # all paths lost: I/O waits in the queue for 60 checks x polling_interval = 300 s, then fails
    features             "0"
    dev_loss_tmo         60
    recheck_wwid         yes
    skip_kpartx          yes  # no partition maps on the volumes, see below
  }
}

blacklist {
  device {
    vendor  ".*"
    product ".*"
  }
}

blacklist_exceptions {
  wwid "3624a9370.*"
  device {
    vendor "PURE"
  }
}
```

`skip_kpartx yes` stops kpartx from creating partition maps (`<wwid>-part1` and so on) on top of the multipath map of a volume. The host never needs them: the guest reads its own partition table. A partition map holds the multipath map exclusively, and with `cache=writeback` on the disk the guest then loses writes, see [I/O errors in a guest on discard or zeroes](troubleshooting.md#known-issues). The packaged rule `59-pure-storage-kpartx.rules` sets the same flag through udev, so the plugin does not depend on this line; keep it so that the setting holds without the rule too. `multipathd reconfigure` applies the new setting to the existing maps without recreating them, and removes none of the partition maps that already exist.

### udev Rules

The package installs two udev rules files into `/usr/lib/udev/rules.d/`; a source install copies them (see below).

`59-pure-storage-kpartx.rules` keeps kpartx away from the multipath maps of Pure volumes: it sets the flag that `60-kpartx.rules` reads as `skip_kpartx`, so the file must be read before `60-kpartx.rules`. It acts on the next udev event of a map; partition maps that exist already stay until the map is removed, or until they are removed by hand, see [I/O errors in a guest on discard or zeroes](troubleshooting.md#known-issues).

`68-pure-storage.rules` holds two things.

- A rule that keeps LVM of the host away from the multipath maps of Pure volumes. Without it the host may activate the volume group that a guest keeps on its disk, and the volume cannot be deactivated afterwards, see [LVM inside a volume](troubleshooting.md#known-issues). The file must be read before `69-lvm.rules`. The rule also applies to LVM that you run on a Pure volume on the host: its volume groups are not activated by udev, activate them with `vgchange -ay`.
- The kernel settings that Pure recommends for FlashArray volumes (`none` scheduler, `add_random`, `rq_affinity`, SCSI timeout, `max_sectors_kb`), see the Linux recommended settings of Pure. They are applied by the same file, so a file with these settings that you install yourself (for example `99-pure-storage.rules`) only repeats them.

To turn a file off on a node, mask it with a symlink to `/dev/null` of the same name, for example `ln -s /dev/null /etc/udev/rules.d/68-pure-storage.rules` (a file in `/etc/udev/rules.d` replaces the packaged one of the same name, and a symlink to `/dev/null` disables the rules, see `udev(7)`; an empty file of the same name does the same), then run `udevadm control --reload-rules`.

### iSCSI Configuration

Initiate iSCSI according to the Proxmox Guidelines.

```bash
sudo iscsiadm -m discovery -t sendtargets -p <PURE ISCSI ADAPTER IP>
sudo iscsiadm -m node --op update -n node.startup -v automatic
```

> [!CAUTION]
> As long as there are no hostX entries in /sys/class/iscsi_host/ the plugin is not ready to be used.

## Installation

> [!IMPORTANT]
> If you are using a cluster setup, install the plugin on all nodes in the cluster. The storage configuration is synchronized via corosync, but the plugin code must be present on each node.

### Debian package (recommended)

The package installs the dependencies and makes upgrades a single command. Replace `<PACKAGE_VERSION>` with the desired version (for example `0.0.1`); the [releases page](https://github.com/kolesa-team/pve-purestorage-plugin/releases) lists them.

```bash
PACKAGE_VERSION="<PACKAGE_VERSION>"
wget "https://github.com/kolesa-team/pve-purestorage-plugin/releases/download/v${PACKAGE_VERSION}/libpve-storage-purestorage-perl_${PACKAGE_VERSION}-1_all.deb"
sudo apt install ./libpve-storage-purestorage-perl_${PACKAGE_VERSION}-1_all.deb
```

To upgrade, run the same commands with the new version. To uninstall: `sudo apt remove libpve-storage-purestorage-perl`.

### From source

For development, or to install from a checkout:

```bash
sudo apt-get update
sudo apt-get install -y libpve-common-perl libwww-perl libhttp-message-perl liburi-perl libjson-xs-perl multipath-tools kpartx dmsetup udev
git clone https://github.com/kolesa-team/pve-purestorage-plugin.git
cd pve-purestorage-plugin
sudo install -D -m 644 PureStoragePlugin.pm /usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm
sudo install -m 644 udev/59-pure-storage-kpartx.rules udev/68-pure-storage.rules /usr/lib/udev/rules.d/
sudo udevadm control --reload-rules
sudo systemctl restart pvedaemon.service pveproxy.service pvestatd.service
```

### Verify

```bash
pvesm status
# the purestorage type is now available
```
