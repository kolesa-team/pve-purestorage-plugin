# Proxmox VE Plugin for Pure Storage as Multipath iSCSI Source

This plugin enables the integration of Pure Storage arrays with Proxmox Virtual Environment (VE) using multipath iSCSI or Fibre Channel (FC). It allows you to use Pure Storage as a backend for your virtual machine disks, providing high performance and reliability.

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
  - [Multipath Configuration](#multipath-configuration)
- [Installation](#installation)
  - [Manual](#manual)
  - [APT](#apt)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## Features
- Easily enable and configure multipathing iSCSI to the Pure Array
- Storage based snapshots
  - Snapshots are presented in Proxmox like any other native Snapshot to a VM
  - Snapshots are created by the Pure Array, making them deduped and instant
- Instant storage migration
  - The plugin will automatically map the iSCSI volumes needed on the host the VM is being migrated to

## Prerequisites

Before installing and using this plugin, ensure that your Proxmox VE environment meets the following prerequisites.

### Multipath Configuration

To ensure correct operation with Pure Storage, you need to configure your multipath settings appropriately. Specifically, you need to set find_multipaths to no in your multipath.conf file. This setting disables the automatic detection of multipath devices, which is necessary for Pure Storage devices to be correctly recognized.

Below is an example of how your multipath.conf file should look when configured for Pure Storage arrays:

```
defaults {
  polling_interval 2
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
    no_path_retry        0
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
## iSCSI Configuration

Initiate iSCSI according to the Proxmox Guidelines.

```bash
sudo iscsiadm -m discovery -t sendtargets -p <PURE ISCSI ADAPTER IP>
sudo iscsiadm -m node --op update -n node.startup -v automatic
```

> [!CAUTION]
> As long as there are no hostX entries in /sys/class/iscsi_host/ the plugin is not ready to be used.

## Installation

There are two methods to install the plugin: manual installation and APT package installation.

### Manual

To manually install the plugin, follow these steps:

```bash
# Clone repository
git clone https://github.com/kolesa-team/pve-purestorage-plugin.git
# Navigate to the Plugin Directory
cd pve-purestorage-plugin
# Create the custom plugin directory if it does not already exist
mkdir /usr/share/perl5/PVE/Storage/Custom
# Copy plugin to custom plugin directory
cp PureStoragePlugin.pm /usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm
# Restart Proxmox VE
systemctl restart pve-cluster.service pvedaemon.service pvestatd.service pveproxy.service pvescheduler.service
```

### APT

**Note**: Replace `<PACKAGE_VERSION>` with your desired version number (e.g., `0.0.1`).

```bash
PACKAGE_VERSION="<PACKAGE_VERSION>" curl -L -o libpve-storage-purestorage-perl.deb "https://github.com/kolesa-team/pve-purestorage-plugin/releases/download/v$PACKAGE_VERSION/libpve-storage-purestorage-perl_$PACKAGE_VERSION-1_all.deb"

sudo apt install ./libpve-storage-purestorage-perl.deb
```

## Configuration
> [!TIP]
> If your are using a cluster setup - this step needs to be executed only on one note of the cluster - corosync will do the rest for you.

After installing the plugin, you need to configure Proxmox VE to use it. Since Proxmox VE does not currently support adding custom storage plugins via the GUI, you will need to open shell and use `pvesm` command to add it:

```bash
pvesm add purestorage <storage_id> \
   --nodes <proxmox_node_list> \
   --address https://<purestorage_fqdn_or_ip> \
   --token <purestorage_api_token> \
   --vgname <purestorage_volume_group_name> \
   --hgsuffix <purestorage_host_suffix>
   --content images
```

Alternatively, you can manually edit the storage configuration file `/etc/pve/storage.cfg`.

```
purestorage: <storage_id>
  nodes <proxmox_node_list>
  address https://<purestorage_fqdn_or_ip>
  token <purestorage_api_token>
  vgname <purestorage_volume_group_name>
  hgsuffix <purestorage_host_suffix>
  content images
```

| Parameter | Description |
| --------- | ----------- |
| storage_id | The storage identifier (name under which it will appear in the Storage list) |
| nodes | (`optional`) A comma-separated list of Proxmox node names. Use this parameter to limit the plugin to specific nodes in your cluster. If omitted, the storage is available to all nodes. |
| address | The URL or IP address of the Pure Storage API endpoint. Ensure that the Proxmox VE nodes can reach this address over the network. |
| token | The API token used for authentication with the Pure Storage array. This token must have sufficient permissions to create and manage volumes. |
| vgname | (`optional`, conflicts with `podname`) The volume group name where virtual disks will be stored. This should match the configuration on your Pure Storage array. |
| podname | (`optional`, conflicts with `vgname`) The pod name where virtual disks will be stored. This should match the configuration on your Pure Storage array. |
| vnprefix | (`optional`) The prefix to prepend to name of virtual disks. |
| hgsuffix | (`optional`) A suffix that is appended to the hostname when the plugin interacts with the Pure Storage array. This can help differentiate hosts if necessary. |
| content | Specifies the types of content that can be stored. For virtual machine disk images, use images. |
| protocol | (`optional`, default is `iscsi`) Specifies the storage protocol (iscsi, fc) |

> **_NOTE:_** Ensure that the token and other sensitive information are kept secure and not exposed publicly.

Example Configuration:

```
purestorage: pure
  address https://purestorage.example.com
  token abc123
  vgname pure_vg
  content images
```

## Troubleshooting

If you encounter issues while using the plugin, consider the following steps:

- Check Service Status: Ensure that the Proxmox VE services are running correctly. You can restart the services if necessary:

```bash
sudo systemctl restart pve-cluster.service pvedaemon.service pvestatd.service pveproxy.service pvescheduler.service
```

- Verify Network Connectivity: Ensure that the Proxmox VE nodes can reach the Pure Storage array over the network. Check for firewall rules or network issues that might be blocking communication.
- Review Logs: Check the Proxmox VE logs for any error messages related to storage or the plugin. Logs are typically found in /var/log/pve.
  These commands are helpful for troubleshooting:
  ```bash
  multipath -ll -v3 #diagnose issues with the multipath service
  iscsiadm -m node #list what iscsi nodes are mounted
  ls -l /dev/mapper/3624a9370* #list wwids of Pure mapped devices on the system
  ```
- Multipath Configuration: Verify that your multipath.conf is correctly configured and that multipath devices are recognized. Use multipath -ll to list the current multipath devices.
- API Token Permissions: Ensure that the API token used has the necessary permissions to create and manage volumes on the Pure Storage array.
- Plugin Updates: Ensure you are using the latest version of the plugin. Check the GitHub repository for updates.

### Known issues

- `lvm inside a volume`: If you plan to use LVM inside a volume, it is better to add purestorage volumes to the ignore list to avoid scanning.

```bash
cat /etc/lvm/lvmlocal.conf
...
devices {
  global_filter=["r|/dev/zd.*|","r|/dev/rbd.*|","r|/dev/mapper/3624a9370.*|"]
}
```

## Contributing

Contributions to this project are welcome.
