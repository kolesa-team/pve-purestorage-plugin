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
sudo systemctl restart pvedaemon.service pveproxy.service pvestatd.service
```

### Verify

```bash
pvesm status
# the purestorage type is now available
```
