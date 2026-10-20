#!/usr/bin/env python3
"""Runs migration_under_load for the combinations of guest controller and data disk options that matter: the default and the writeback cache on virtio-scsi-single.  The controller of the guest does not matter to the plugin (it hands a block device to QEMU), only the cache mode does, so only that is varied.

The official suite creates its guests with fixed parameters (virtio-scsi-single, no cache or iothread options),
so the modes in which writes sit in a cache and a removal has to flush it are covered here:

  tests/e2e/matrix.py                    # all combinations on the first node of NODES
  tests/e2e/matrix.py --node <host>      # start on that node (the older PVE first, see the README)
  tests/e2e/matrix.py --only 3 4         # only the combinations with these numbers

The disk size is the default of the test (twice the RAM of the node, see tests/e2e/README.md); PLUGIN_LOAD_DISK_GB
overrides it. The result of every combination is printed and written to tests/e2e/logs/matrix.txt.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOG_DIR = HERE / "logs"

# (controller, data disk options): iothread works with virtio-scsi-single only
COMBINATIONS = [
  ("virtio-scsi-single", ""),
  ("virtio-scsi-single", "cache=writeback,discard=on,iothread=1"),
]


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("--node", help="node to run on (default: the first of NODES)")
  parser.add_argument("--only", nargs="*", type=int, help="numbers (from 1) of the combinations to run")
  args = parser.parse_args()

  selected = [(i, *c) for i, c in enumerate(COMBINATIONS, 1) if not args.only or i in args.only]
  LOG_DIR.mkdir(parents=True, exist_ok=True)
  lines = []
  failed = 0
  for number, scsihw, options in selected:
    # buffered data sits dirty in the host cache only with cache=writeback, so only there it is written and checked
    env = dict(os.environ, PLUGIN_LOAD_SCSIHW=scsihw, PLUGIN_LOAD_DISK_OPTIONS=options, PLUGIN_LOAD_DIRTY_GB="2" if "writeback" in options else "0")
    command = [sys.executable, "-u", str(HERE / "run_suite.py"), "--guest", "migration_under_load"] + (["--node", args.node] if args.node else [])
    print(f"=== combination {number}: controller={scsihw} disk options='{options}'", flush=True)
    done = subprocess.run(command, env=env, capture_output=True, text=True)
    result = next((l for l in done.stdout.splitlines() if l.startswith("=== migration_under_load:")), f"no result (exit {done.returncode})")
    (LOG_DIR / f"matrix-{number}.log").write_text(done.stdout + done.stderr)
    line = f"{number}: controller={scsihw} options='{options}' -> {result.removeprefix('=== migration_under_load: ')}"
    print(line, flush=True)
    lines.append(line)
    failed += not result.startswith("=== migration_under_load: ok")
  (LOG_DIR / "matrix.txt").write_text("\n".join(lines) + "\n")
  print(f"=== {len(selected)} combinations, {failed} failed", flush=True)
  return 1 if failed else 0


if __name__ == "__main__":
  sys.exit(main())
