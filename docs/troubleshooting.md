# Troubleshooting

## Debug Logging

Debug output is written to syslog. Set the level (0 off, 1 basic, 2 verbose with HTTP details, 3 trace) in the storage configuration, or for one command with the environment variable, which `debug` in the configuration overrides:

```bash
pvesm set <storage_id> --debug 1            # persistent; --debug 0 turns it off
PURESTORAGE_DEBUG=2 pvesm status <storage_id>   # one command; use 3 for authentication problems
```

Example output of `PURESTORAGE_DEBUG=1 pvesm list <storage_id>`:

```text
Debug :: activate_storage (<storage_id>)
Debug :: list_images (<storage_id>, vmid=all)
Debug :: Read token cache from: /etc/pve/priv/purestorage/<storage_id>_array0.json
Debug :: Token is valid (age: 125s)
```

Read the messages and the token cache:

```bash
journalctl -u pvedaemon -f | grep -E "(Debug ::|Info ::|Warning ::|Error ::)"
ls -lah /etc/pve/priv/purestorage/
jq 'del(.auth_token)' /etc/pve/priv/purestorage/<storage_id>_array0.json
```

## Messages of the status, removal and activation

**The storage is inactive for up to 30 seconds after the array failed.** The plugin keeps a failure marker and does not call the array while it is younger than 30 seconds. To retry at once, remove `/run/pve-purestorage/<storage_id>.failed`; the mechanism is in [architecture](architecture.md#status-failure-marker).

**`Device "sdX" still has the WWID ... of a removed volume, it answers ...: rescanning`.** The array gave a LUN number of a removed volume to a new one, and a SCSI device of the old volume was still on the node. The plugin rescans it, and it becomes a path of the new volume. If the message repeats for volumes that you did not remove, look for a deactivation that failed earlier (the message below).

**`paths of volume "..." are still present after the removal: ...`.** The removal deleted the paths of the volume but sysfs still lists them after 10 seconds: stale devices that fail as soon as the volume is gone from the array. Delete them by hand with `echo 1 > /sys/block/<sdX>/device/delete`.

**`Timeout while waiting for multipath map "..." to be released`.** Something holds the multipath device or one of its partition maps (a reader, a mount, an active LVM volume group inside a partition: see the filter below). The deactivation fails and leaves the volume as it was; release the holder and deactivate again.

**`Mapping of volume "..." failed, the volume was connected before and is left as it was`.** The activation of a volume that was connected before failed. The plugin does not roll it back, because a running guest may hold it. Look for the first error above this message.

## Known issues

**LVM inside a volume:**

When a guest keeps LVM on its disk, udev (`69-lvm.rules`) runs `pvscan` for the multipath map of the volume as soon as it appears, and the host activates the volume group of the guest. The logical volume stands on top of the map and holds it open: `multipathd remove map` refuses, the plugin retries for 30 seconds and then the deactivation fails with `Timeout while waiting for multipath map ... to be released`. The volume stays connected to the node (after a migration it ends up connected to two nodes) and its paths stay on the node until the logical volume is removed and the volume is deactivated again.

This was seen on PVE 8 (LVM 2.03.16), where a `global_filter` that rejects `/dev/mapper/...` and the `by-id` names did not stop it (`pvscan` is given the single device `/dev/dm-N`); it did not happen on PVE 9 (LVM 2.03.31). The packaged rule `68-pure-storage.rules` takes the LVM mark off the map before `69-lvm.rules` reads it, see [udev Rules](install.md#udev-rules). Check that it is in effect with `udevadm info /dev/mapper/<wwid> | grep ID_FS_TYPE` (no `LVM2_member`). To get a stuck volume out, remove the logical volume of the guest (`dmsetup ls --tree` shows it on top of the map, `dmsetup remove <name>`) and deactivate the volume again.

**Debug output contamination ([#56](https://github.com/kolesa-team/pve-purestorage-plugin/issues/56)):** with debug logging enabled, debug messages can end up in the output of commands that must stay clean (`qm showcmd`, `pvesm path`) and break tools that parse it. Set `--debug 0` for such commands (see Debug Logging).

**Volume auto-mount issues ([#59](https://github.com/kolesa-team/pve-purestorage-plugin/issues/59)):** the device path of a deactivated volume does not work, which affects `qm showcmd` and backup tools that read the path directly. Activate the volume first (`pvesm path` after the volume is active, or start the guest).

## Diagnostic commands

```bash
# multipath
multipath -ll                              # all devices; add -v3 for debugging
multipath -ll | grep -A 10 "3624a9370"     # Pure devices only
systemctl reload multipathd                # reload the configuration

# iSCSI
iscsiadm -m session -P 3                   # sessions in detail
iscsiadm -m node                           # discovered targets
iscsiadm -m session --rescan

# volumes and device mapper
ls -l /dev/mapper/3624a9370*
lsblk | grep "3624a9370"
/lib/udev/scsi_id --whitelisted --device=/dev/mapper/3624a9370<wwid>
dmsetup ls --tree
dmsetup info /dev/mapper/3624a9370<wwid>
kpartx -l /dev/mapper/3624a9370<wwid>      # partitions of a volume

# plugin
pvesm list <storage_id>
pvesm status <storage_id>
pvesm alloc <storage_id> <vmid> test-volume 1G && pvesm free <storage_id>:test-volume

# network
nc -zv <array_iscsi_ip> 3260
```

Test the API login with the token from a variable, not from the command line history; the answer carries the session token in the `x-auth-token` header:

```bash
read -rs PURE_TOKEN
curl -k -s -o /dev/null -w '%{http_code}\n' -X POST -H "api-token: ${PURE_TOKEN}" https://<array_address>/api/2.26/login
unset PURE_TOKEN
```

If the Proxmox services misbehave after a change: `sudo systemctl restart pvedaemon.service pvestatd.service pveproxy.service`.
