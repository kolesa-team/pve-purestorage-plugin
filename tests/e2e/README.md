# End-to-end tests

The plugin is validated on a real Proxmox VE cluster against a real Pure Storage array with the storage plugin validation suite of Proxmox itself: the [proxmox-e2e-tests](https://git.proxmox.com/?p=proxmox-e2e-tests.git;a=summary) repository, pinned as the git submodule `tests/e2e/proxmox-e2e-tests`. Its tests create and destroy VMs and volumes, so run them only against a test stand. The hardware-free unit tests are in `tests/unit/`.

## Requirements

Packages and tools, by where they are needed:

| Where | What | Why |
| --- | --- | --- |
| laptop | `python3` 3.9 or newer, `git`, `ssh`, `tar` | `run_suite.py` uses only the standard library |
| every node | `libnet-openssh-perl` (`apt install libnet-openssh-perl`) | the Perl framework of the suite loads `Net::OpenSSH` |
| the node that runs the guest tests | `libguestfs-tools` (`apt install libguestfs-tools`, pulls in many packages: use a test node), `curl`, internet access | on the first `--guest` run the suite downloads a Debian cloud image and installs the guest agent into it with `virt-customize`; the image is cached in `/var/cache/proxmox-storage-plugin-tests` |

Also needed:

- `git submodule update --init tests/e2e/proxmox-e2e-tests`
- SSH access by key as `root` to the nodes.
- A Pure Storage storage already defined in `/etc/pve/storage.cfg`; for the cluster migration tests a cluster of two nodes.
- The plugin from the branch installed on the nodes (see below).

## Configure

```bash
cp .env.example .env
```

`.env` is git-ignored and may hold secrets. Keys:

| Key | Meaning |
| --- | --- |
| `NODES` | comma-separated node hosts; the first one runs the suite (`--node` or `LIVE_NODES` overrides) |
| `SSH_USER`, `SSH_KEY` | SSH user, path to the private key (empty uses the ssh default identity) |
| `STORAGE_ID` | storage under test, passed to the suite as `PLUGIN_STORAGE_ID` |
| `PLUGIN_PATH` | where `deploy.py` puts the plugin on a node (default `/usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm`) |
| `PLUGIN_BACKUP_FALLBACK_STORAGE` | storage with the `backup` content for the backup tests when the storage under test has none, for example `local`; without it those tests are skipped |
| `PLUGIN_MIGRATION_TARGET_STORAGE` | storage that the disk and migration tests move a disk to (default: the first other enabled storage with `images` on the node) |
| `PLUGIN_MIGRATION_TARGET_NODE` | node that the cluster migration tests migrate to (default: the first other online node) |
| `PLUGIN_QGA_IMAGE` | guest image with the QEMU guest agent (default: a Debian cloud image, downloaded and prepared on first use) |
| `PLUGIN_TEST_ISO_URL` | ISO that the download test fetches; without it the test is skipped |
| `PLUGIN_LOAD_*`, `PLUGIN_LIFECYCLE_ROUNDS`, `PLUGIN_GUEST_PASSWORD` | variables of the extended tests, see [Extended tests](#extended-tests) |

## Run

The order for a full check of a branch:

```bash
# 1. put the plugin of the branch on a node (one node at a time)
tests/e2e/deploy.py <node>

# 2. the default set (no guest needed)
tests/e2e/run_suite.py

# 3. the guest-based tests too (the first run prepares the guest image, a few minutes)
tests/e2e/run_suite.py --guest
```

`run_suite.py` options:

```bash
tests/e2e/run_suite.py --list             # the tests of the default set
tests/e2e/run_suite.py disk_resize        # chosen tests
tests/e2e/run_suite.py --node <host>      # another node than the first of NODES
```

The script copies the suite to `/var/tmp/proxmox-e2e` on the node, runs the tests with the timeouts of the suite manifest and prints for each: `ok`, `SKIP`, `KNOWN` or `FAIL`, the counts of `ok` and `not ok` lines, the exit code and how many volumes the test left on the storage. The exit status is 1 when a test failed.

Run the tests one after another, and never two runs on different nodes of one cluster at once: the tests pick free VMIDs themselves, and the nodes share `/cluster/nextid`, which reserves nothing. Two runs get the same VMID and the second creation fails with `100.conf failed: File exists`.

A `SKIP` is a capability the plugin does not provide (for example `rootdir` for containers or linked-clone bases) or a missing prerequisite; the reason is printed.

`--jobs N` runs the tests that do not need the node alone N at a time and the others after them (the guest set takes about 60% of the time with `--jobs 4`). Overlapping tests can pick the same VMID. A test that fails with `already exists`, `File exists` or `can't lock file` is repeated once on its own; any other failure is real and is not repeated. The reason of the first failure is printed and its log is kept as `tests/e2e/logs/<test>.first.log`. `migration_under_load`, `hard_stop_integrity` and `volume_lifecycle_loop` (they read the journal of the node), the tests with fixed volume names and the ones that provoke plugin errors never overlap another test.

`migration_under_load` starts only from the first node of `NODES`: a guest started on a newer node gets a machine type that the older node cannot run, so `run_suite.py --node <other>` leaves the test out and prints that it did.

### Clean-up after a run

The array keeps the name of a destroyed volume until it erases it. `io_integrity` and `disk_thin_discard` allocate `vm-<nextid>-disk-0` and fail on a taken name, so before them `run_suite.py` creates empty placeholder VMs on the ids whose name is taken. After the run, also when it fails or is interrupted, it removes the placeholders, erases the volumes that run destroyed and prints the leftover VMs and volumes of the storage. Volumes destroyed before the run are not touched. Erasing is irreversible for those volumes and needs the array to allow eradication.

### Known failures

A failure that does not come from the plugin is listed in `KNOWN_FAILURES` of `run_suite.py` with the PVE major version it belongs to. The run prints it as `KNOWN` with the reason and does not count it as a failure. Today that is `io_integrity_guest` on PVE 8: the API client posts the script through `HTTP::Request::Common` of `libhttp-message-perl` 6.44 (Debian bookworm), which turns LF into CRLF, so the guest shell fails with `set: Illegal option -`; the test fails the same way on a storage without this plugin.

## Deploy the plugin to the stand

Tests do not install anything. To put the plugin from the current branch on a node:

```bash
tests/e2e/deploy.py <node>
tests/e2e/deploy.py --rollback <node>
```

Deploy saves the installed file as `PureStoragePlugin.pm.<md5>.bak`, copies the new one, compares md5, restarts `pvedaemon`, `pveproxy` and `pvestatd` (the PVE web interface is briefly unavailable, running VMs are not affected) and checks `pvesm status`. Deploy one node at a time. Rollback restores the newest backup.

## Extended tests

`tests/e2e/extended/` holds tests the Proxmox suite does not have, written the same way (Perl, the `Proxmox::Test::*` framework, a `testcases.ron` manifest) and run by `run_suite.py` next to the official ones: `unmap_busy_map` and `stale_lun_heal` are in the default set, the others need `--guest` (tag `storage-plugin-guest`).

- `migration_under_load`: `fio` in the guest writes checksummed blocks while the guest migrates online to the second node and back, with buffered writes pending before each migration; it checks that the disk stays readable, no path degrades, the target ends with as many paths as the source, neither node logs disk errors and the plugin logs no removal or activation problem. Then the guest shuts down, starts on the other node, and `fio` verifies every acknowledged and every buffered block. It needs a cluster of two nodes with root ssh trust and the older PVE first in `NODES` (see above).
- `hard_stop_integrity`: the guest, with `cache=writeback` on its data disk, is stopped the hard way (`qm stop`) while it writes; the blocks of the `fio` jobs that had ended must read back after a cold start.
- `volume_lifecycle_loop`: a guest with a new data disk per round (`virtio-scsi-single`, `virtio-scsi-pci`) writes, destroys the disk, and checks that nothing of the volume stays on the node.
- `unmap_busy_map` and `stale_lun_heal` provoke plugin errors on purpose (a held map, a stale SCSI device) and run in the default set.
- `activate_failure_keeps_volume`: the mapping of an activation is made to fail. A volume of a running guest and an active volume that nothing holds keep their paths and their multipath map; a volume that the call connected itself is rolled back and activates normally afterwards.

`fio` is not in the image of the suite, so the first run builds a copy of the prepared guest image with `fio` (`virt-customize`, about 650 MB, cached beside it in `/var/cache/proxmox-storage-plugin-tests`). `PLUGIN_QGA_IMAGE` can name an image of your own that has `fio` and the guest agent.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PLUGIN_LOAD_SCSIHW` | `virtio-scsi-single` | guest controller, for example `virtio-scsi-pci` (not `lsi`: the cloud kernel of the guest image has no driver for it, the guest cannot find its boot disk) |
| `PLUGIN_LOAD_DISK_OPTIONS` | none | extra options of the data disk, for example `cache=writeback,discard=on,iothread=1` |
| `PLUGIN_LOAD_DISK_GB` | twice the RAM of the node, 20 to 512 | data disk size: much larger than the caches on the way, or the writes never reach the storage (thin provisioned, only written blocks count) |
| `PLUGIN_LOAD_DIRTY_GB` | 2 | size of the buffered write before each migration and the shutdown, 0 turns it off (`matrix.py` sets it only for `writeback`: other cache modes leave no dirty data in the host cache) |
| `PLUGIN_LIFECYCLE_ROUNDS` | one per guest controller | rounds of `volume_lifecycle_loop` |
| `PLUGIN_GUEST_PASSWORD` | none | root password of the image with `fio`, for a login on the console of a test guest; baked in when the image is built (delete the `-fio.qcow2` image on the node to change it); the image of the suite itself has no login |

`tests/e2e/matrix.py` runs `migration_under_load` for two combinations of disk options on `virtio-scsi-single`: the default cache and `writeback` (the controller of the guest does not matter to the plugin, which hands a block device to QEMU; only the cache mode does) and writes the result of each to `tests/e2e/logs/matrix.txt`:

```bash
tests/e2e/matrix.py            # all combinations on the first node of NODES
tests/e2e/matrix.py --only 2   # one combination
```

## Safety

- Never print `/etc/pve/storage.cfg` unmasked: it holds API tokens and CHAP passwords.
- The suite creates VMs with the next free VMID and names that carry the storage id; check `pvesh get /cluster/resources --type vm` and `pvesm list <storage>` after a failed run.
