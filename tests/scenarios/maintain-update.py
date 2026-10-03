#!/usr/bin/env python3
# device-free test of `raspi-provision update`: fake ssh/rsync on PATH record each
# remote command, then assert the order. apt lists must be refreshed before the
# depends install, or install fails against stale lists on a long-idle device.

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BIN = os.environ.get("BIN", str(REPO / "target/debug/raspi-provision"))
FAKE = '#!/bin/sh\necho "$(basename "$0") $*" >> "$CALL_LOG"\n'


def run_update(tmp: Path) -> list[str]:
    fakebin, project, log = tmp / "bin", tmp / "project", tmp / "calls.log"
    for d in (fakebin, project / "depends", project / "overlay/etc"):
        d.mkdir(parents=True)
    for name in ("ssh", "rsync"):
        (fakebin / name).write_text(FAKE)
        (fakebin / name).chmod(0o755)
    (project / "depends/extra").write_text("testpkg\n")
    (project / "overlay/etc/marker").write_text("x\n")
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", CALL_LOG=str(log), ADDRESS="192.0.2.1")
    subprocess.run([BIN, "-C", str(project), "update"], env=env, check=True, cwd=tmp)
    return log.read_text().splitlines()


def index_of(calls: list[str], needle: str) -> int:
    for i, c in enumerate(calls):
        if needle in c:
            return i
    sys.exit(f"[test] ERROR: no call matching '{needle}' in:\n" + "\n".join(calls))


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        calls = run_update(Path(t))
    print("\n".join(f"[test] call: {c}" for c in calls), file=sys.stderr)
    order = [index_of(calls, n) for n in ("rsync ", "apt-get update", "apt-get -y install", "apt-get -y full-upgrade")]
    if order != sorted(order):
        sys.exit("[test] ERROR: maintain-update scenario FAILED: want rsync, update, install, full-upgrade")
    if "testpkg" not in calls[order[2]]:
        sys.exit("[test] ERROR: maintain-update scenario FAILED: project depends not installed")
    print("[test] maintain-update scenario PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
