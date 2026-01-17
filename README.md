# Proxmox VE Plugin for Pure Storage as Multipath iSCSI Source

[![Checks](https://github.com/kolesa-team/pve-purestorage-plugin/actions/workflows/checks.yml/badge.svg)](https://github.com/kolesa-team/pve-purestorage-plugin/actions/workflows/checks.yml)

This plugin enables the integration of Pure Storage arrays with Proxmox
Virtual Environment (VE) using multipath iSCSI or Fibre Channel (FC).
It allows you to use Pure Storage as a backend for your virtual machine
disks, providing high performance and reliability.

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
  - [Multipath Configuration](#multipath-configuration)
  - [iSCSI Configuration](#iscsi-configuration)
- [Installation](#installation)
  - [Manual Installation](#manual-installation)
  - [Debian Package Installation (Recommended)](#debian-package-installation-recommended)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
  - [Debug Logging](#debug-logging)
  - [Service Status](#service-status)
  - [Diagnostic Commands](#diagnostic-commands)
  - [Known issues](#known-issues)
- [Contributing](#contributing)

## Features

- Easily enable and configure multipathing iSCSI to the Pure Array
- **Active Cluster support (Experimental)** - Automatic volume connection
  on both arrays in Active Cluster configuration
  - Volumes are automatically connected to hosts on both primary and
    secondary arrays
  - Ensures high availability and optimal connectivity in Active Cluster
    setups
- Storage based snapshots
  - Snapshots are presented in Proxmox like any other native Snapshot to a VM
  - Snapshots are created by the Pure Array, making them deduped and instant
- Instant storage migration
  - The plugin will automatically map the iSCSI volumes needed on the
    host the VM is being migrated to

## Prerequisites

Before installing and using this plugin, ensure that your Proxmox VE
environment meets the following prerequisites.

### Multipath Configuration

To ensure correct operation with Pure Storage, you need to configure your
multipath settings appropriately. Specifically, you need to set
find_multipaths to no in your multipath.conf file. This setting disables
the automatic detection of multipath devices, which is necessary for Pure
Storage devices to be correctly recognized.

Below is an example of how your multipath.conf file should look when
configured for Pure Storage arrays:

```text
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

### iSCSI Configuration

Initiate iSCSI according to the Proxmox Guidelines.

```bash
sudo iscsiadm -m discovery -t sendtargets -p <PURE ISCSI ADAPTER IP>
sudo iscsiadm -m node --op update -n node.startup -v automatic
```

> [!CAUTION]
> As long as there are no hostX entries in /sys/class/iscsi_host/ the
> plugin is not ready to be used.

## Installation

There are two methods to install the plugin: manual installation and Debian
package installation via APT.

> [!IMPORTANT]
> If you are using a cluster setup, install the plugin on all nodes in the
> cluster. The storage configuration will be automatically synchronized via
> corosync, but the plugin code must be present on each node.

### Manual Installation

Manual installation is useful for development or when you want to install
from source.

#### Step 1: Install required dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
  libwww-perl \
  libjson-perl \
  libjson-xs-perl
```

#### Step 2: Clone the repository

```bash
git clone https://github.com/kolesa-team/pve-purestorage-plugin.git
cd pve-purestorage-plugin
```

#### Step 3: Install the plugin

```bash
# Create the custom plugin directory
sudo mkdir -p /usr/share/perl5/PVE/Storage/Custom

# Copy plugin file
sudo cp PureStoragePlugin.pm /usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm

# Set correct permissions
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm
```

#### Step 4: Restart Proxmox VE services

```bash
sudo systemctl restart pvedaemon.service pveproxy.service
```

#### Step 5: Verify installation

```bash
pvesm status
# The purestorage type should now be available
```

### Debian Package Installation (Recommended)

Installing via Debian package is the recommended method as it handles
dependencies automatically and provides easy updates.

#### Step 1: Download the package*

Replace `<PACKAGE_VERSION>` with the desired version (e.g., `0.0.1`). Check
the [releases page](https://github.com/kolesa-team/pve-purestorage-plugin/releases)
for available versions.

```bash
PACKAGE_VERSION="<PACKAGE_VERSION>"
wget "https://github.com/kolesa-team/pve-purestorage-plugin/releases/download/v${PACKAGE_VERSION}/libpve-storage-purestorage-perl_${PACKAGE_VERSION}-1_all.deb"
```

#### Step 2: Install the package

```bash
sudo apt install ./libpve-storage-purestorage-perl_${PACKAGE_VERSION}-1_all.deb
```

#### Step 3: Verify installation

```bash
dpkg -l | grep libpve-storage-purestorage-perl
# Should show the installed package version
```

#### To upgrade to a newer version

```bash
# Download new version
PACKAGE_VERSION="<NEW_VERSION>"
wget "https://github.com/kolesa-team/pve-purestorage-plugin/releases/download/v${PACKAGE_VERSION}/libpve-storage-purestorage-perl_${PACKAGE_VERSION}-1_all.deb"

# Upgrade
sudo apt install ./libpve-storage-purestorage-perl_${PACKAGE_VERSION}-1_all.deb
```

#### To uninstall

```bash
sudo apt remove libpve-storage-purestorage-perl
```

## Configuration

> [!TIP]
> If you are using a cluster setup - this step needs to be executed only
> on one node of the cluster - corosync will do the rest for you.

After installing the plugin, you need to configure Proxmox VE to use it.
Since Proxmox VE does not currently support adding custom storage plugins
via the GUI, you will need to open shell and use `pvesm` command to add it:

```bash
pvesm add purestorage <storage_id> \
   --nodes <proxmox_node_list> \
   --address \
   https://<purestorage_fqdn_or_ip> \
   --token <purestorage_api_token> \
   --vgname <purestorage_volume_group_name> \
   --hgsuffix <purestorage_host_suffix>
   --content images
```

Alternatively, you can manually edit the storage configuration file
`/etc/pve/storage.cfg`.

```text
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
| address | The URL or IP address of the Pure Storage API endpoint. Ensure that the Proxmox VE nodes can reach this address over the network. For high availability or Active Cluster configuration (experimental), you can specify multiple arrays separated by commas (e.g., `https://array1.example.com,https://array2.example.com`). When multiple arrays are specified, the plugin automatically connects volumes to hosts on all arrays. |
| token | The API token used for authentication with the Pure Storage array. This token must have sufficient permissions to create and manage volumes. For multiple arrays, specify tokens separated by commas in the same order as addresses. Each token must have permissions for its corresponding array. |
| vgname | (`optional`, conflicts with `podname`) The volume group name where virtual disks will be stored. This should match the configuration on your Pure Storage array. |
| podname | (`optional`, conflicts with `vgname`) The pod name where virtual disks will be stored. This should match the configuration on your Pure Storage array. |
| vnprefix | (`optional`) The prefix to prepend to name of virtual disks. |
| hgsuffix | (`optional`) A suffix that is appended to the hostname when the plugin interacts with the Pure Storage array. This can help differentiate hosts if necessary. |
| content | Specifies the types of content that can be stored. For virtual machine disk images, use images. |
| protocol | (`optional`, default is `iscsi`) Specifies the storage protocol (`iscsi`, `fc`). |
| check_ssl | (`optional`, default is `no`) Verify the server's TLS certificate. Set to `yes` to enable SSL certificate verification. |
| token_ttl | (`optional`, default is `3600`) Session token time-to-live in seconds. The plugin caches PureStorage API session tokens in `/etc/pve/priv/purestorage/` (automatically replicated across cluster nodes). Tokens are proactively refreshed at 80% of TTL to prevent expiration during operations. |
| debug | (`optional`, default is `0`) Enable debug logging. Levels: 0=off, 1=basic (token operations, main calls), 2=verbose (HTTP details, validation), 3=trace (all internals). Environment variable `PURESTORAGE_DEBUG` can be used as fallback when `debug` is not set in config. |

> **_NOTE:_** Ensure that the token and other sensitive information are
> kept secure and not exposed publicly.

Example Configuration:

**Single Array:**

```text
purestorage: pure
  address https://purestorage.example.com
  token abc123
  vgname pure_vg
  hgsuffix ""
  content images
```

**Active Cluster (Multiple Arrays) - Experimental:**

```text
purestorage: pure-cluster
  address https://array1.example.com,https://array2.example.com
  token token1,token2
  vgname pure_vg
  content images
```

> [!NOTE]
> When multiple arrays are specified (Active Cluster configuration -
> experimental feature), the plugin automatically connects volumes to hosts
> on both arrays. This ensures high availability - if one array fails,
> volumes remain accessible through the other array. The plugin handles
> connection management on all arrays transparently.

## Troubleshooting

If you encounter issues while using the plugin, consider the following
steps:

### Debug Logging

The plugin provides detailed debug logging to help diagnose issues. Debug
output is written to syslog and can be viewed in Proxmox logs.

**Enable debug logging:**

Persistent (via configuration):

```bash
pvesm set <storage_id> --debug 1
```

Temporary (for single command, when debug is not set in config):

```bash
PURESTORAGE_DEBUG=1 pvesm list <storage_id>
```

> **Note:** If `debug` is set in storage configuration, it takes priority
> over `PURESTORAGE_DEBUG` environment variable.

**Debug levels:**

- `0` - Off (production, default)
- `1` - Basic (token operations, main function calls, volume operations)
- `2` - Verbose (HTTP requests, token validation, API responses)
- `3` - Trace (all internal operations, detailed flow)

**Example debug output:**

```bash
PURESTORAGE_DEBUG=1 pvesm list pure-n1
Debug :: activate_storage (pure-n1)
Debug :: list_images (pure-n1, vmid=all)
Debug :: Read token cache from: /etc/pve/priv/purestorage/pure-n1_array0.json
Debug :: Token is valid (age: 125s)
Debug :: Using cached token from file (age: 125s)
```

**Common debug scenarios:**

Debug volume creation:

```bash
PURESTORAGE_DEBUG=2 pvesm alloc <storage_id> <vmid> <volname> 10G
```

Debug volume deletion:

```bash
PURESTORAGE_DEBUG=2 pvesm free <storage_id>:<volname>
```

Debug API authentication issues:

```bash
PURESTORAGE_DEBUG=3 pvesm status <storage_id>
```

**View debug logs:**

Check Proxmox daemon logs:

```bash
journalctl -u pvedaemon -f
```

Filter for PureStorage plugin messages:

```bash
journalctl -u pvedaemon | grep -E "(Debug ::|Info ::|Warning ::|Error ::)"
```

Check token cache status:

```bash
ls -lah /etc/pve/priv/purestorage/
cat /etc/pve/priv/purestorage/<storage_id>_array0.json | jq .
```

### Service Status

Ensure that the Proxmox VE services are running correctly. You can restart
the services if necessary:

```bash
sudo systemctl restart pve-cluster.service pvedaemon.service pvestatd.service pveproxy.service pvescheduler.service
```

### Diagnostic Commands

**Multipath diagnostics:**

List all multipath devices with details:

```bash
multipath -ll
```

Verbose multipath debugging:

```bash
multipath -ll -v3
```

Show only Pure Storage devices:

```bash
multipath -ll | grep -A 10 "3624a9370"
```

Reload multipath configuration:

```bash
systemctl reload multipathd
```

**iSCSI diagnostics:**

List all iSCSI sessions:

```bash
iscsiadm -m session
```

Show detailed session information:

```bash
iscsiadm -m session -P 3
```

List all discovered targets:

```bash
iscsiadm -m node
```

Rescan iSCSI sessions:

```bash
iscsiadm -m session --rescan
```

**PureStorage volume diagnostics:**

List all Pure Storage mapped devices:

```bash
ls -l /dev/mapper/3624a9370*
```

Show device information:

```bash
lsblk | grep "3624a9370"
```

Check device WWIDs:

```bash
/lib/udev/scsi_id --whitelisted --device=/dev/mapper/3624a9370<wwid>
```

Show device mapper table:

```bash
dmsetup table
```

Show device mapper dependencies:

```bash
dmsetup deps -o devname
```

List all device mapper devices:

```bash
dmsetup ls --tree
```

Show detailed info for specific device:

```bash
dmsetup info /dev/mapper/3624a9370<wwid>
```

**Partition management (kpartx):**

List partitions on a device:

```bash
kpartx -l /dev/mapper/3624a9370<wwid>
```

Add partition mappings:

```bash
kpartx -a /dev/mapper/3624a9370<wwid>
```

Remove partition mappings:

```bash
kpartx -d /dev/mapper/3624a9370<wwid>
```

Sync partition table:

```bash
kpartx -u /dev/mapper/3624a9370<wwid>
```

**Storage plugin diagnostics:**

List all volumes on storage:

```bash
pvesm list <storage_id>
```

Show storage status:

```bash
pvesm status <storage_id>
```

Scan for new volumes:

```bash
pvesm scan <storage_id>
```

Test volume allocation (dry-run):

```bash
pvesm alloc <storage_id> <vmid> test-volume 1G
pvesm free <storage_id>:test-volume
```

**Network connectivity:**

Test API endpoint connectivity:

```bash
curl -k https://<array_address>/api/2.30/arrays
```

Test with API token:

```bash
curl -k -X POST https://<array_address>/api/2.30/login \
  -H "Content-Type: application/json" \
  -d '{"api_token":"<your_token>"}'
```

Check iSCSI portal connectivity:

```bash
nc -zv <array_iscsi_ip> 3260
```

**Common issues:**

- **API Token Permissions**: Ensure the API token has sufficient permissions
  to create and manage volumes on the Pure Storage array
- **Multipath Configuration**: Verify multipath.conf is correctly configured
  and multipath devices are recognized
- **Network Connectivity**: Check firewall rules and network routes to Pure
  Storage array
- **Plugin Updates**: Ensure you are using the latest version of the plugin

### Known issues

**LVM inside a volume:**

If you plan to use LVM inside a volume, it is better to add purestorage
volumes to the ignore list to avoid scanning.

```bash
cat /etc/lvm/lvmlocal.conf
...
devices {
  global_filter=["r|/dev/zd.*|","r|/dev/rbd.*|",
                 "r|/dev/mapper/3624a9370.*|"]
}
```

**Debug output contamination ([#56](https://github.com/kolesa-team/pve-purestorage-plugin/issues/56)):**

When debug logging is enabled, debug messages may contaminate command
outputs that should be clean (e.g., `qm showcmd`, `pvesm path`). This can
break tools that parse these outputs.

Workaround: Disable debug logging when using commands that need clean output:

```bash
pvesm set <storage_id> --debug 0
```

Or use temporary debug only when needed:

```bash
PURESTORAGE_DEBUG=1 <command>
```

**Volume auto-mount issues ([#59](https://github.com/kolesa-team/pve-purestorage-plugin/issues/59)):**

The `filesystem_path` function returns device paths that may not work
reliably when volumes are deactivated. This affects operations like
`qm showcmd` and backup tools (e.g., Veeam) that need direct access to
volume paths.

Current behavior: Volumes are activated on-demand and may deactivate when
not in use.

Workaround: Ensure volumes are activated before accessing them directly.
For automated workflows, consider implementing volume activation in your
scripts.

Note: A proper solution using autofs for automatic volume mounting is being
evaluated.

## Contributing

Contributions to this project are welcome.
