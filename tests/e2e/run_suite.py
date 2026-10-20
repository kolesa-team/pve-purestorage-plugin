#!/usr/bin/env python3
"""Runs the Proxmox storage plugin validation suite (the proxmox-e2e-tests submodule) on a node.

The suite is a set of standalone Perl scripts configured by PLUGIN_* environment variables, so the
Rust runner is not needed: this copies the suite to the node, runs the tests from its manifest one
after another and reports ok / not ok counts, skips and leftover volumes of each.

  tests/e2e/run_suite.py                     # default set (tag storage-plugin), first node of NODES
  tests/e2e/run_suite.py --guest             # also the guest-based tests (QEMU guest agent image)
  tests/e2e/run_suite.py disk_resize disk_clone
  tests/e2e/run_suite.py --node <host> --list
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from common import load_env, nodes, ssh, ssh_argv

HERE = Path(__file__).resolve().parent
SUITE = HERE / "proxmox-e2e-tests"
EXTENDED = HERE / "extended"
LOG_DIR = HERE / "logs"
PERL_HELPER = HERE / "destroyed_volumes.pl"
REMOTE_DIR = "/var/tmp/proxmox-e2e"
# tests that allocate vm-<nextid>-disk-0 by a fixed name and fail when an earlier run used that name
FIXED_NAME_TESTS = {"io_integrity", "disk_thin_discard"}
# tests that never overlap with another one: they allocate by a fixed name, measure the whole node, check its journal (and
# would take the errors of another test for their own), or provoke the plugin errors that those tests would take
SERIAL_TESTS = FIXED_NAME_TESTS | {"migration_under_load", "hard_stop_integrity", "volume_lifecycle_loop", "unmap_busy_map", "stale_lun_heal"}
# what a test says when it lost the race for a VM id against a test that runs next to it: only such a failure is repeated
RACE_MARKS = ("already exists", "File exists", "can't lock file")
# tests that migrate the guest to another node and so start on the node with the oldest QEMU, the first of NODES: a guest
# started on a newer node gets a machine type the older one cannot run
FIRST_NODE_ONLY = {"migration_under_load"}
# (test, PVE major version) -> why it fails there although the plugin is not involved; reported as KNOWN, not as a failure
KNOWN_FAILURES = {
  ("io_integrity_guest", 8): "the API client posts the script with CRLF line breaks (libhttp-message-perl 6.44 of Debian bookworm); the same failure on a storage without this plugin",
}
# suite directory name on the node -> where it comes from; the tests find the Proxmox/ framework one level up
SUITE_DIRS = {"storage-plugin-tests": SUITE / "storage-plugin-tests", "extended": EXTENDED}


def manifest() -> list[tuple[str, int, str, str]]:
  """[(name, timeout, tag, suite directory)] from the testcases.ron of the official suite and of extended/."""
  pattern = r'run: "\./tests/(\w+)\.pl",\s*timeout: (\d+),.*?tag: "([\w-]+)"'
  return [(m.group(1), int(m.group(2)), m.group(3), name) for name, path in SUITE_DIRS.items() for m in re.finditer(pattern, (path / "testcases.ron").read_text(), re.S)]


def copy_suite(cfg: dict, node: str) -> None:
  """The framework and the official tests from the submodule, our extended/ tests beside them."""
  parts = [("Proxmox", SUITE), ("storage-plugin-tests", SUITE), ("extended", HERE)]
  command = f"rm -rf {REMOTE_DIR} && mkdir -p {REMOTE_DIR} && tar -C {REMOTE_DIR} -xf - 2>/dev/null"
  for index, (name, base) in enumerate(parts):
    tar = subprocess.run(["tar", "-C", str(base), "--exclude=.git", "-cf", "-", name], capture_output=True, check=True)
    done = subprocess.run(ssh_argv(cfg, node, command if index == 0 else f"tar -C {REMOTE_DIR} -xf - 2>/dev/null"), input=tar.stdout, capture_output=True)
    if done.returncode:
      sys.exit(f"{node}: copying the suite failed: {done.stderr.decode().strip()}")


def plugin_env(cfg: dict) -> str:
  env = {"PLUGIN_STORAGE_ID": cfg["STORAGE_ID"]}
  env.update({k: v for k, v in {**cfg, **os.environ}.items() if k.startswith("PLUGIN_") and v})
  return " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())


def volumes_on_storage(cfg: dict, node: str) -> int:
  done = ssh(cfg, node, f"pvesm list {shlex.quote(cfg['STORAGE_ID'])} 2>/dev/null | grep -c images")
  return int(done.stdout.strip() or 0)


def destroyed_volumes(cfg: dict, node: str) -> set[str]:
  """Names of the destroyed, not yet erased volumes of the storage: the array keeps such a name taken."""
  done = subprocess.run(ssh_argv(cfg, node, f"perl - list {shlex.quote(cfg['STORAGE_ID'])}"), input=PERL_HELPER.read_text(), capture_output=True, text=True)
  if done.returncode:
    sys.exit(f"{node}: listing destroyed volumes failed: {done.stderr.strip()}")
  return set(done.stdout.split())


def vmids(cfg: dict, node: str) -> set[int]:
  done = ssh(cfg, node, "pvesh get /cluster/resources --type vm --output-format json | grep -o '\"vmid\":[0-9]*' | cut -d: -f2")
  return {int(v) for v in done.stdout.split()}


def make_placeholders(cfg: dict, node: str, destroyed: set[str]) -> list[int]:
  """Empty VMs on the free ids whose name vm-<id>-disk-0 is taken, up to the first run of free names, so that
  the tests that allocate vm-<nextid>-disk-0 get a name the array has not kept."""
  used = vmids(cfg, node)
  placeholders, clean_run, vmid = [], 0, 100
  while clean_run < 5:
    if vmid not in used:
      if f"vm-{vmid}-disk-0" in destroyed:
        placeholders.append(vmid)
        clean_run = 0
      else:
        clean_run += 1
    vmid += 1
  if placeholders:
    ssh(cfg, node, f"for i in {' '.join(map(str, placeholders))}; do qm create $i --memory 16 >/dev/null 2>&1; done", timeout=600)
  return placeholders


def erase_new_destroyed(cfg: dict, node: str, known: set[str]) -> set[str]:
  """Erases the volumes destroyed since `known` (so that the next test can reuse their names) and returns the
  destroyed volumes that are still there."""
  current = destroyed_volumes(cfg, node)
  new = sorted(current - known)
  if not new:
    return current
  done = subprocess.run(ssh_argv(cfg, node, f"perl - eradicate {shlex.quote(cfg['STORAGE_ID'])} {' '.join(map(shlex.quote, new))}"), input=PERL_HELPER.read_text(), capture_output=True, text=True)
  failed = [l for l in done.stdout.splitlines() if l.startswith("failed")]
  if failed:
    print(f"    erasing destroyed volumes: {len(failed)} of {len(new)} failed", flush=True)
    for line in failed[:3]:
      print(f"      {line}", flush=True)
  erased = {l.split()[1] for l in done.stdout.splitlines() if l.startswith("eradicated")}
  return current - erased


def destroy_test_guest(cfg: dict, node: str, vmid: int) -> bool:
  """Stops and destroys a guest left behind by a test (killed by its timeout, for example), only when its name is the
  one the suite gives its guests: a VM somebody else created meanwhile is never touched."""
  script = (
    f"read n s name <<EOF\n$(pvesh get /cluster/resources --type vm --output-format json | python3 -c \"import sys,json;"
    f"[print(v['node'],v['status'],v.get('name','-')) for v in json.load(sys.stdin) if v['vmid']=={vmid}]\")\nEOF\n"
    f"case \"$name\" in storage-plugin-*) ;; *) exit 3;; esac; "
    f"[ \"$s\" = running ] && pvesh create /nodes/$n/qemu/{vmid}/status/stop >/dev/null 2>&1 && sleep 5; "
    f"pvesh delete /nodes/$n/qemu/{vmid} --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1"
  )
  return ssh(cfg, node, script, timeout=300).returncode == 0


def clean_up(cfg: dict, node: str, placeholders: list[int], vmids_before: set[int]) -> None:
  """Removes the placeholders and reports what is left."""
  if placeholders:
    ssh(cfg, node, f"for i in {' '.join(map(str, placeholders))}; do qm destroy $i --purge >/dev/null 2>&1; done", timeout=600)
  leftover_vms = sorted(vmids(cfg, node) - vmids_before)
  destroyed_guests = [v for v in leftover_vms if destroy_test_guest(cfg, node, v)]
  print(f"=== cleanup: leftover VMs {leftover_vms or 'none'} (destroyed {destroyed_guests or 'none'}), volumes on the storage {volumes_on_storage(cfg, node)}", flush=True)


def run_test(cfg: dict, node: str, name: str, timeout: int, suite_dir: str) -> tuple[str, int, list[str], str | None, int, list[str]]:
  command = f"cd {REMOTE_DIR}/{suite_dir} && {plugin_env(cfg)} timeout {timeout} perl tests/{name}.pl 2>&1"
  LOG_DIR.mkdir(parents=True, exist_ok=True)
  # the log grows line by line while the test runs, so that a monitor can follow it
  proc = subprocess.Popen(ssh_argv(cfg, node, command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
  killer = threading.Timer(timeout + 60, proc.kill)
  killer.start()
  lines = []
  with open(LOG_DIR / f"{name}.log", "w") as log:
    for line in proc.stdout:
      log.write(line)
      log.flush()
      lines.append(line.rstrip("\n"))
  returncode = proc.wait()
  killer.cancel()
  done = subprocess.CompletedProcess(proc.args, returncode)
  ok = sum(1 for l in lines if l.startswith("ok"))
  not_ok = [l for l in lines if l.startswith("not ok")]
  skip = next((l for l in lines if "# SKIP" in l), None)
  if skip:
    status = "SKIP"
  elif not_ok or done.returncode:
    status = "FAIL"
  else:
    status = "ok"
  return status, ok, not_ok, skip, done.returncode, lines


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("tests", nargs="*", help="test names (default: the whole tag set)")
  parser.add_argument("--node", help="node to run on (default: the first of NODES)")
  parser.add_argument("--guest", action="store_true", help="also run the storage-plugin-guest tests")
  parser.add_argument("--list", action="store_true", help="list the tests and exit")
  parser.add_argument("--jobs", type=int, default=1, help="tests run at the same time (default 1); the tests that need the node for themselves still run alone, after the others")
  args = parser.parse_args()

  if not SUITE.joinpath("storage-plugin-tests").exists():
    sys.exit("the suite is missing: git submodule update --init tests/e2e/proxmox-e2e-tests")
  tags = {"storage-plugin", "storage-plugin-guest"} if args.guest else {"storage-plugin"}
  selected = [(n, t, tag, d) for n, t, tag, d in manifest() if (n in args.tests if args.tests else tag in tags)]
  if args.list:
    for name, timeout, tag, _ in selected:
      print(f"{tag:22} {timeout:5} {name}")
    return 0

  cfg = load_env()
  missing = [k for k in ("NODES", "STORAGE_ID") if not cfg.get(k)]
  if missing:
    sys.exit(f"missing keys in .env: {', '.join(missing)}")
  node = args.node or nodes(cfg)[0]
  if node != nodes(cfg)[0]:
    for name in sorted(FIRST_NODE_ONLY & {n for n, *_ in selected}):
      print(f"=== {name}: not run here, it starts from the first node of NODES ({nodes(cfg)[0]})", flush=True)
    selected = [t for t in selected if t[0] not in FIRST_NODE_ONLY]

  copy_suite(cfg, node)
  before = volumes_on_storage(cfg, node)
  vmids_before = vmids(cfg, node)
  destroyed_before = destroyed_volumes(cfg, node)
  placeholders = make_placeholders(cfg, node, destroyed_before) if FIXED_NAME_TESTS & {n for n, *_ in selected} else []
  try:
    return run_selected(cfg, node, selected, before, destroyed_before, args.jobs)
  finally:
    clean_up(cfg, node, placeholders, vmids_before)


def pve_major(cfg: dict, node: str) -> int:
  return int(ssh(cfg, node, "pveversion | sed 's|pve-manager/||; s|\\..*||'").stdout.strip() or 0)


def run_selected(cfg: dict, node: str, selected: list, before: int, destroyed: set[str], jobs: int = 1) -> int:
  major = pve_major(cfg, node)
  lock = threading.Lock()
  failed = []
  raced = set()

  def run_and_report(test: tuple, left: int | None) -> str:
    name, timeout, _, suite_dir = test
    status, ok, not_ok, skip, code, lines = run_test(cfg, node, name, timeout, suite_dir)
    known = KNOWN_FAILURES.get((name, major)) if status == "FAIL" else None
    if known:
      status = "KNOWN"
    with lock:
      shown = "n/a" if left is None else left
      print(f"=== {name}: {status} ok={ok} not_ok={len(not_ok)} exit={code} volumes_left={shown}", flush=True)
      for line in not_ok + ([skip] if skip else []) + ([l for l in lines[-3:]] if status == "FAIL" and not not_ok else []):
        print(f"    {line}", flush=True)
      if known:
        print(f"    known failure on PVE {major}: {known}", flush=True)
      if status == "FAIL":
        if any(mark in line for line in lines for mark in RACE_MARKS):
          raced.add(name)
        # the reason of a failure that a retry may turn green must stay visible
        for line in [l for l in lines if l.lstrip().startswith("#") or "failed" in l.lower()][:6]:
          print(f"    {line.strip()}", flush=True)
        print(f"    full output: {LOG_DIR / (name + '.log')}", flush=True)
    return status

  together = [t for t in selected if jobs > 1 and t[0] not in SERIAL_TESTS]
  alone = [t for t in selected if t not in together]
  if together:
    print(f"=== {len(together)} tests, {jobs} at a time ...", flush=True)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
      results = list(pool.map(lambda t: (t, run_and_report(t, None)), together))
    destroyed = erase_new_destroyed(cfg, node, destroyed)
    # tests that overlap can pick the same VM id: such a failure gets one more try on its own, any other one is real
    for test, status in results:
      if status == "FAIL" and test[0] in raced:
        print(f"=== {test[0]} failed next to other tests, once more on its own ...", flush=True)
        shutil.copy(LOG_DIR / f"{test[0]}.log", LOG_DIR / f"{test[0]}.first.log")
        status = run_and_report(test, volumes_on_storage(cfg, node) - before)
      if status == "FAIL":
        failed.append(test[0])
      # the retry destroyed volumes too, and a test that follows may allocate their names
      destroyed = erase_new_destroyed(cfg, node, destroyed)
  for test in alone:
    print(f"=== {test[0]} ...", flush=True)
    status = run_and_report(test, volumes_on_storage(cfg, node) - before)
    if status == "FAIL":
      failed.append(test[0])
    destroyed = erase_new_destroyed(cfg, node, destroyed)
  print(f"=== {len(selected)} tests, {len(failed)} failed")
  return 1 if failed else 0


if __name__ == "__main__":
  sys.exit(main())
