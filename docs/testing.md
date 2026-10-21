# Testing

The plugin has two test layers: unit tests that need no hardware, and live tests that run against a Proxmox VE node and a Pure Storage array.

## Unit tests

Perl `Test::More` files in `tests/unit/`. They load the real `PureStoragePlugin.pm` and call its functions. They need `perl`, `Test::More`, `JSON::XS` and `libwww-perl`.

```bash
# all unit tests
prove tests/unit/

# the same through the wrapper that CI uses
./tests/run_tests.sh

# one file
perl tests/unit/test_token_cache.t
```

| File | Covers |
| --- | --- |
| `test_activate_volume.t` | a failed mapping deactivates the volume again and reports the original error, even when the rollback fails; a volume that was connected before is left as it was |
| `test_alloc_image.t` | the `.raw` suffix of the content API is cut from the volume name, names are validated |
| `test_api_version.t` | the storage API version reported to PVE 8 and PVE 9, no "older storage API" warning inside the tested range |
| `test_block_device_action.t` | offline, delete and rescan of a path through sysfs, a refused write is logged and does not stop the cleanup, a vanished path is skipped |
| `test_clone_imported.t` | a clone of an imported protection-group snapshot restores from the exact array name, a native snapshot by its Proxmox name |
| `test_command_validation.t` | external command lookup: an unknown command dies, a missing command dies with its path, `check_commands` agrees with the lookup |
| `test_device_paths.t` | paths of a volume found by WWID, one list of paths for resize and unmap even when the by-id link points at a single path, sysfs read under one root |
| `test_multipath_remove.t` | `multipathd remove map` is retried quietly until the map is released, a map that stays held is an error |
| `test_multipath_resize.t` | `multipathd resize map` is retried until the map accepts it, a map that never does is an error |
| `test_pgroup_names.t` | snapshot name sanitizing (also for groups in a pod), names of colliding and long groups (at most 40 characters), parent and description parsing, skipping PVE-created snapshots |
| `test_pgroup_snapshot_sync.t` | snapshot entries built from a VM config without drives added after the snapshot, importing a group without taking over a snapshot of the user, parents after a removed snapshot |
| `test_sync_children.t` | the finished runs of the sync are reaped, a run that still works and a child of another part of the daemon are left alone |
| `test_sync_files.t` | the state of the sync (time of the last run, lock) is kept in one directory of the node, created with mode 0700 |
| `test_sync_array_snapshots.t` | the whole sync of one storage against a scripted array: import, a second cycle, removal of a vanished snapshot, an incomplete answer, a VM of another node, one read of each config |
| `test_retry_logic.t` | `purestorage_http_request` against a scripted user agent: re-login and one retry on HTTP 401, no retry on other errors, network error on a non-JSON answer, `x-next-token` pagination |
| `test_snapshot_delete.t` | a snapshot is destroyed and then erased, the erase has no `replication_snapshot` parameter (the array then erases only replication snapshots) |
| `test_stale_lun.t` | a stale device on a reused LUN is found by its live WWID and rescanned, the LUN of a mapped volume, the wait that may end without the path |
| `test_status_backoff.t` | after a failed status the storage is inactive without a call to the array for 30 seconds, the marker goes after an answer |
| `test_token_cache.t` | token cache write, read, validity window, expiry cleanup, corrupt and missing files, file mode 0600 |
| `test_unmap_volume.t` | order of the removal (map, offline, array disconnect, delete), the paths are deleted although the array disconnect fails, paths that survive the delete are an error |

`tests/unit/lib/PluginLoader.pm` loads the plugin. On a PVE node the real `PVE::*` modules are used; elsewhere the stubs in `tests/unit/lib/PVE/` stand in for them (appended to `@INC`, so real modules win). The command paths and the token cache directory are fixed in the plugin, so the tests cover what holds on any machine.

The `Tests` workflow (`.github/workflows/tests.yml`) runs `tests/run_tests.sh` on Ubuntu 26.04 with Perl 5.36 and 5.40, the Perl versions of PVE 8 and PVE 9.

## End-to-end tests

The plugin is validated on Proxmox VE nodes with a real Pure Storage array by the storage plugin validation suite of Proxmox (`proxmox-e2e-tests`, a pinned git submodule). It covers the VM disk lifecycle, clone, snapshot and rollback, resize, disk and cluster migration, backup and I/O integrity. The tests create and delete VMs and volumes on the array, run only on request and never in CI by default.

```bash
git submodule update --init tests/e2e/proxmox-e2e-tests
tests/e2e/run_suite.py
```

Setup, the `.env` keys, the guest-based tests and the deploy helper are described in [tests/e2e/README.md](../tests/e2e/README.md).
