# Architecture

`PureStoragePlugin.pm` is a Proxmox VE custom storage plugin (package `PVE::Storage::Custom::PureStoragePlugin`, base class `PVE::Storage::Plugin`). PVE calls its methods for volume operations. The plugin translates them into Pure Storage REST calls and into block-device work on the node: SCSI scan, multipath and device cleanup.

## Volumes on the array

- A PVE volume `vm-<vmid>-disk-<n>` is a volume on the array. Its array name is `<prefix><volname>`, where the prefix comes from `vgname` (`<vgname>/`), or from `podname` (`<podname>::`), plus the optional `vnprefix`. `vgname` and `podname` cannot be set together.
- The node's host object on the array is `<node name>-<hgsuffix>` (just the node name when `hgsuffix` is empty). Activating a volume connects it to that host.
- With several addresses in `address` (Active Cluster, experimental), the plugin sends the same connect and disconnect calls to every array. Tokens are matched to addresses by position.
- Snapshots are array snapshots named `<volume>.snap-<snapname>`. `clone_image` restores a snapshot into a new volume.

## Activation path

`activate_volume` runs two steps:

1. `purestorage_volume_connection` connects the volume to the node's host on all arrays. An existing connection is not an error; the call reports whether it made the connection itself.
2. `map_volume` rescans SCSI for the protocol (`iscsi` or `fc`; `nvme` is rejected as not implemented), waits up to 30 seconds for the device path and adds a multipath map when `multipathd` does not have one. Devices of a removed volume that stayed on a reused LUN are rescanned first, so that the new volume can appear there.

When `map_volume` fails, `activate_volume` disconnects and unmaps the volume only if this call connected it. A volume that was connected before may be held by a running guest or activated again by a resize or a backup, and taking its paths would take the disk from the guest. The original error is re-thrown.

`deactivate_volume` calls `purestorage_unmap_volume` with a callback that disconnects the volume from the host. The steps are: flush buffers (`sync`, `blockdev --flushbufs`, `udevadm settle`), remove the multipath map (a refusal is retried for up to 30 seconds; when the map stays busy the deactivation fails, nothing goes offline and the volume stays connected), take every path of the volume offline (a path that is already gone is skipped), disconnect on the array (the callback; the paths are deleted even when it fails), delete the paths, and wait up to 10 seconds until they are gone from sysfs, otherwise die naming the ones that are left. `unmap_volume` alone does the local part and does not disconnect the volume on the array. The device path is `/dev/disk/by-id/wwn-0x<wwn>`, where the WWN is the Pure vendor prefix plus the volume serial, lowercase, last 32 characters. `free_image` deactivates the volume and then removes it from the array; removal also cleans LVM and partition mappings on the device.

## Authentication and token cache

The plugin logs in to each array with the API token and keeps the session token in `/etc/pve/priv/purestorage/<storage_id>_array<n>.json` (mode 0700 directory, replicated across the cluster by `pmxcfs`). A cached token is reused while its age is below 80% of `token_ttl` with a random ±2.5% jitter, so cluster nodes do not refresh at the same moment. A request that fails with HTTP 401 on a cached token is retried once: the plugin first re-reads the cache file, because another node may have refreshed the token, and logs in again only when that does not help.

## Capacity reporting

`status` reports array capacity from `arrays/space`. With `podname` set, it reports the pod quota when one is set and falls back to array capacity otherwise. Used space is clamped to total so PVE never sees negative free space.

## Status failure marker

PVE asks every storage for its status one after another and without a timeout, so an array that does not answer would hold each round for the HTTP timeout. When `status` fails, it writes a marker `/run/pve-purestorage/<storage_id>.failed` (a directory of the node: the way to the array is a property of the node, and `/run` is cleared by a reboot). While the marker is younger than 30 seconds, `status` reports the storage inactive without calling the array. The first successful answer removes the marker. To retry at once, remove the file. The protection-group sync keeps its state in the same directory (`sync-<storage_id>.ts`, the time of the last run, and `sync-<storage_id>.lock`, the lock of a run); the session token stays in the cluster-wide `/etc/pve/priv/purestorage`.

## Protection-group snapshot sync

With `pgroup_sync` enabled, `status` forks a background run (at most once per `pgroup_sync_interval`) that imports array protection-group snapshots into QEMU VM configs as snapshot entries. The fork keeps `pvestatd` and storage polls from blocking. See [configuration](configuration.md#protection-group-snapshot-sync) for the settings.

- An entry holds only the drives of the VM that were in the snapshot: a drive added later is not in it, and a rollback does not touch it.
- When a snapshot is gone from the array, the run removes its entry from the VM config and moves the parent references that pointed at it.
- Two groups can give the same Proxmox name (`a-b.c` and `a.b-c`). The group with the smaller parent keeps the name, the others get the UTC time of their snapshot (`<name>-YYYYMMDD-HHMMSS`).

## Supported PVE features

`volume_has_feature` answers `snapshot`, `rename` and `sparseinit` for current volumes, and `clone` and `copy` for current volumes and snapshots. Not implemented: base images and templates (`create_base`), `volume_import`, and `filesystem_path` for a snapshot.

## Debug output

Debug level comes from the `debug` property, or from `PURESTORAGE_DEBUG` when the property is unset. Messages go to syslog and can also end up in command output, which breaks tools that parse it; see [troubleshooting](troubleshooting.md#known-issues).
