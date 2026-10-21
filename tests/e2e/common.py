"""Shared helpers of the e2e scripts: the .env parser and ssh to a node."""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]


def load_env() -> dict[str, str]:
  """KEY=value lines of .env (LIVE_ENV overrides the path); `export `, one pair of quotes and a trailing # comment are tolerated."""
  cfg = {}
  for line in Path(os.environ.get("LIVE_ENV", ROOT / ".env")).read_text().splitlines():
    if m := re.match(r"\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*?)\s*$", line):
      value = m.group(2)
      cfg[m.group(1)] = q.group(2) if (q := re.match(r"""(["'])(.*?)\1\s*(?:#.*)?$""", value)) else re.sub(r"\s+#.*$", "", value)
  return cfg


def nodes(cfg: dict[str, str]) -> list[str]:
  return [n.strip() for n in os.environ.get("LIVE_NODES", cfg.get("NODES", "")).split(",") if n.strip()]


def ssh_argv(cfg: dict[str, str], node: str, command: str) -> list[str]:
  key = ["-i", cfg["SSH_KEY"]] if cfg.get("SSH_KEY") else []
  return ["ssh", *key, *SSH_OPTS, f"{cfg.get('SSH_USER', 'root')}@{node}", command]


def ssh(cfg: dict[str, str], node: str, command: str, timeout: int | None = None) -> subprocess.CompletedProcess:
  return subprocess.run(ssh_argv(cfg, node, command), capture_output=True, text=True, timeout=timeout)


def ssh_ok(cfg: dict[str, str], node: str, command: str, timeout: int | None = None) -> str:
  done = ssh(cfg, node, command, timeout)
  if done.returncode:
    raise RuntimeError(f"{node}: {command} failed ({done.returncode}): {done.stderr.strip()}")
  return done.stdout
