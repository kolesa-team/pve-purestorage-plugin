# Plugin notes, for agents

Facts about `PureStoragePlugin.pm` that are not obvious from the code. Read the relevant part before changing activation, removal, resize or allocation. What the plugin does step by step is in [architecture](../architecture.md); this file keeps the reasons.

## Removing the local paths of a volume

- A volume is one SCSI disk per path plus a multipath map. The by-id link `/dev/disk/by-id/wwn-0x...` may point at a single path while the map is not up, so all paths are found by WWID in sysfs (`block_device_paths_by_wwid`), not through that link. `lun_paths` is the one place that lists the paths of a volume (slaves of the link plus paths by WWID); resize and unmap both use it.
- The order of the removal (map, offline, array disconnect, delete) exists because iscsid rescans the sessions regularly and brings a removed path back while the volume is still connected on the array; the path then fails once the array disconnects the volume. A path that stays after the delete is a stale device: `purestorage_unmap_volume` waits for the paths to leave sysfs (`$PATH_REMOVAL_TIMEOUT`) and dies naming them. A name counts as left only while it carries the WWID of the volume: the kernel gives the name of a deleted path to the next volume at once.
- `unmap_volume` keeps the signature `($class, $storeid, $scfg, $volname, $snapname)`: `PVE::Storage::unmap_volume` passes a snapshot name as the fourth argument. Never repurpose an argument of a method that PVE calls.
- Writes into sysfs go through `syswrite` and a refused write is logged: with `print` and `close` the error was lost. The value is written with a trailing newline: the kernel (6.8, PVE 8) answers `Invalid argument` to `offline` in `device/state` without it.

## Activation

- `PVE::Storage::activate_volumes` does not undo a failed activation, and `deactivate_volumes` runs only from some callers. `activate_volume` therefore deactivates the volume itself when `map_volume` fails, but only when this call connected it (`purestorage_volume_connection` returns 1 for a new connection and 0 for `already connected`). A volume connected before may be held by a running guest, and a map that nothing holds at that moment is removed without a refusal, which takes the paths from under the guest.

## Stale devices on a reused LUN

- The array gives the LUN number of a removed volume to the next volume. A device of the old volume that stayed on the node keeps its old WWID in sysfs (`device/wwid` is read when the device is created and a host scan does not read it again), so the new volume does not appear on that LUN. `heal_stale_paths` finds such devices by comparing the cached WWID with the live one (`scsi_id`) and rescans them (`device/rescan` reads the VPD pages again). A device that does not answer is left alone: a path that is down is not a proof of a reused LUN. With the LUN of the volume only the devices on it are read.

## Resize

- `multipathd resize map` refuses while the paths of a LUN report different sizes, so the resize rescans every path (`lun_paths`), not only the slaves of the by-id link.
- `qm resize` of a stopped VM activates the volume and resizes it at once, before multipathd has the map, so `multipathd resize map` fails for a moment. `multipath_resize_map` retries until a timeout. Online resize does not show the problem.

## Names

- The array accepts letters, digits, `_` and `-` in a volume name. The content API of PVE appends the format as a suffix (`vm-100-disk-0.raw`), so `alloc_image` cuts `.raw`.
- A destroyed volume keeps its name until the array erases it (the array does it by itself after 24 hours; an array with eradication disabled never does). Disks are destroyed but not erased on free, so they stay recoverable; `cloudinit` and `state` volumes are erased at once. Reusing a name of a disk fails with "pending eradication".
- `find_free_diskname` lists volumes without the `destroyed` filter, so it sees destroyed volumes and takes the next number (`vm-100-disk-193` after a destroyed `disk-192`). Normal allocation never meets the collision; only a caller that asks for an explicit name on an id used less than 24 hours ago does (two tests of the suite do, which `run_suite.py` handles). The disk number is not bumped inside `alloc_image`.
- The name of a snapshot in a VM config is at most 40 characters: Proxmox refuses a longer one in every API call (clone, rollback, delete). The names that `pgroup_sync` makes are cut to that length.

## Files and permissions

- The token cache file must be created with a numeric `sysopen` mode: `IO::File->new($path, 'w', 0600)` ignores the permissions and gives `0666 & ~umask`.

## Storage API versions

- PVE 8.4 reports `APIVER` 11, PVE 9.2 reports 16 (`APIAGE` 7). PVE accepts a plugin whose `api()` lies between `APIVER - APIAGE` and `APIVER` and warns when it differs from `APIVER`. `api()` returns the host version inside the tested range and the tested version (`$tested_apiver`) above it.
- PVE 8 and PVE 9 differ in more than the API: Debian bookworm and trixie ship different versions of the Perl packages the suite uses, and a guest machine type of a newer node does not run on an older one.

## Not provided

- `snapshot-as-volume-chain` (qcow2 chains of PVE 9) is not used: the array makes native snapshots and the plugin works with `raw` only.
- LXC (`rootdir` in `content`) is declared but not covered by tests. `volume_import` is not implemented and fails at once without leaving anything behind; the base class returns empty `volume_import_formats` and `volume_export_formats` on PVE 8.4 and 9.2, so PVE refuses `pvesm import`, `pvesm export` and remote migration before any data moves.
