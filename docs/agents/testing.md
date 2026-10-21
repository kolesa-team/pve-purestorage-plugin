# Testing, for agents

How to test a change in this repository. Read it before running tests or touching the test stand. The commands, variables and the behaviour of the suite are in `tests/e2e/README.md`; `docs/testing.md` covers the unit tests.

## Order for a change

1. Unit tests (`prove tests/unit/`) and `perltidy -pro=.perltidyrc` on every changed `*.pm`, `*.pl` and test file. Unit tests load the real plugin: call its functions, never copy them into a test.
2. `tests/e2e/deploy.py <node>`, only on request: one node at a time, never while a suite run is active (it restarts `pvedaemon`, `pveproxy` and `pvestatd`, which breaks a running test and an incoming migration).
3. `PLUGIN_BACKUP_FALLBACK_STORAGE=<dir storage> tests/e2e/run_suite.py --guest` on a node of each PVE version (`--node`), only on request. Without the fallback storage the backup tests are skipped.
4. After a failed run check `pvesh get /cluster/resources --type vm`, `pvesm list <storage>` and the SCSI devices of the volume (`/sys/block/sd*/device/wwid`) for leftovers.

## Rules of the stand

- Run suite tests one after another. `--jobs N` is for a faster run and only on request. Two runs on different nodes of one cluster never run at the same time.
- Do not write our own copies of what the Proxmox suite covers; our own tests go to `tests/e2e/extended/`.
- Access (nodes, storage id, ssh key) lives in `.env`: read only the keys. Never print `/etc/pve/storage.cfg` raw.
- Authenticate over ssh by key. A package the suite needs may be installed on the stand; changing `storage.cfg` needs an explicit request.
- Full output of every test run is in `tests/e2e/logs/` (git-ignored).

## Results that are not plugin defects

- A `KNOWN` or `SKIP` line of `run_suite.py` is expected and carries its reason: do not investigate it.
- `migration_under_load` starts on the first node of `NODES`, which must be the node with the older PVE.
