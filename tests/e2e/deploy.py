#!/usr/bin/env python3
"""Puts PureStoragePlugin.pm from this branch on one node, or restores the previous file with --rollback.

  tests/e2e/deploy.py <node>
  tests/e2e/deploy.py --rollback <node>

The previous file is saved as <PLUGIN_PATH>.<md5>.bak. pvedaemon, pveproxy and pvestatd restart, so the
PVE web interface is unavailable for a moment; running VMs are not affected. Deploy one node at a time.
"""
from __future__ import annotations

import argparse
import hashlib
import shlex
import subprocess
import sys

from common import ROOT, SSH_OPTS, load_env, ssh, ssh_ok

DAEMONS = "pvedaemon pveproxy pvestatd"
DEFAULT_PLUGIN_PATH = "/usr/share/perl5/PVE/Storage/Custom/PureStoragePlugin.pm"


def remote_md5(cfg: dict, node: str, path: str) -> str:
  return ssh_ok(cfg, node, f"md5sum {shlex.quote(path)}").split()[0]


def restart_and_check(cfg: dict, node: str) -> str:
  ssh_ok(cfg, node, f"systemctl restart {DAEMONS}")
  storage = shlex.quote(cfg["STORAGE_ID"])
  for line in ssh_ok(cfg, node, f"pvesm status --storage {storage} 2>&1").splitlines():
    fields = line.split()
    if len(fields) >= 3 and fields[0] == cfg["STORAGE_ID"]:
      return fields[2]
  sys.exit(f"{node}: storage {cfg['STORAGE_ID']} not found after the restart")


def deploy(cfg: dict, node: str, path: str) -> str:
  local = ROOT / "PureStoragePlugin.pm"
  want = hashlib.md5(local.read_bytes()).hexdigest()
  old = remote_md5(cfg, node, path)
  if old == want:
    return f"{node}: plugin {want} is already installed, nothing to deploy"
  backup = f"{path}.{old}.bak"
  # mode and owner are kept, the mtime is not: the newest backup is picked by mtime
  ssh_ok(cfg, node, f"cp --preserve=mode,ownership {shlex.quote(path)} {shlex.quote(backup)}")
  key = ["-i", cfg["SSH_KEY"]] if cfg.get("SSH_KEY") else []
  copied = subprocess.run(["scp", *key, *SSH_OPTS, str(local), f"{cfg.get('SSH_USER', 'root')}@{node}:{path}"], capture_output=True, text=True)
  if copied.returncode:
    sys.exit(f"{node}: scp failed: {copied.stderr.strip()}; the previous plugin is saved as {backup}")
  new = remote_md5(cfg, node, path)
  if new != want:
    sys.exit(f"{node}: md5 mismatch after copy: node has {new}, branch file has {want}; the previous plugin is saved as {backup}")
  return f"{node}: deployed {want}, backup {backup}, storage {cfg['STORAGE_ID']} is {restart_and_check(cfg, node)}"


def rollback(cfg: dict, node: str, path: str) -> str:
  done = ssh(cfg, node, f"ls -t {shlex.quote(path)}.*.bak 2>/dev/null | head -1")
  backup = done.stdout.strip()
  if not backup:
    sys.exit(f"{node}: no backup of {path} found")
  ssh_ok(cfg, node, f"cp --preserve=mode,ownership {shlex.quote(backup)} {shlex.quote(path)}")
  return f"{node}: restored {backup}, storage {cfg['STORAGE_ID']} is {restart_and_check(cfg, node)}"


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("node")
  parser.add_argument("--rollback", action="store_true", help="restore the newest backup")
  args = parser.parse_args()
  cfg = load_env()
  if not cfg.get("STORAGE_ID"):
    sys.exit("missing STORAGE_ID in .env")
  path = cfg.get("PLUGIN_PATH") or DEFAULT_PLUGIN_PATH
  print((rollback if args.rollback else deploy)(cfg, args.node, path))
  return 0


if __name__ == "__main__":
  sys.exit(main())
