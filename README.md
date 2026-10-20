# Proxmox VE Plugin for Pure Storage as Multipath iSCSI Source

[![Checks](https://github.com/kolesa-team/pve-purestorage-plugin/actions/workflows/checks.yml/badge.svg)](https://github.com/kolesa-team/pve-purestorage-plugin/actions/workflows/checks.yml)

This plugin enables the integration of Pure Storage arrays with Proxmox Virtual Environment (VE) using multipath iSCSI or Fibre Channel (FC). It allows you to use Pure Storage as a backend for your virtual machine disks, and optionally for LXC container root volumes when configured, providing high performance and reliability.

## Features

- Multipath iSCSI or Fibre Channel access to the Pure array
- Storage based snapshots: created by the array (deduped and instant) and shown in Proxmox like any native snapshot
- Instant storage migration: the volumes are mapped on the target node automatically
- Protection-group snapshot sync for QEMU VMs (opt-in): [configuration](docs/configuration.md#protection-group-snapshot-sync)
- Active Cluster (experimental): volumes are connected on both arrays: [configuration](docs/configuration.md#parameters)
- Optional LXC root volumes, best-effort and community-tested: [configuration](docs/configuration.md#linux-containers-lxc)

## Quick start

1. Install the Debian package on every node of the cluster; [prerequisites and installation](docs/install.md) also cover multipath and iSCSI setup.
2. Add the storage once, on any node:

```bash
pvesm add purestorage <storage_id> \
   --address https://<purestorage_fqdn_or_ip> \
   --token <purestorage_api_token> \
   --vgname <purestorage_volume_group_name> \
   --content images
```

## Documentation

- [Prerequisites and installation](docs/install.md): multipath and iSCSI setup, Debian package and source installation, upgrade
- [Configuration](docs/configuration.md): storage parameters, examples, protection-group snapshot sync
- [Architecture](docs/architecture.md): how the plugin maps PVE volumes to the array and to node devices
- [Testing](docs/testing.md): unit and live tests
- [Troubleshooting](docs/troubleshooting.md): debug logging, diagnostic commands, known issues

## Contributing

Contributions to this project are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
