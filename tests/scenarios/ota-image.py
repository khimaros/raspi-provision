#!/usr/bin/env python3
# device-free test of `raspi-provision ota`: a fake ssh on PATH records each
# remote command and keeps what it was sent. the device must first be handed the
# writer from toolbox/, then the image as gzip, whether it was built compressed or
# raw, named on the command line or found under images/. a truncated gzip stream
# fails on the device, which is why a raw image is compressed on the way.

import gzip
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BIN = os.environ.get("BIN", str(REPO / "target/debug/raspi-provision"))
WRITER = REPO / "toolbox/ota-write"
HOSTNAME = "otatest"
ADDRESS = "192.0.2.1"
IMAGE_BYTES = 5 * 1024 * 1024 + 512
# each call's arguments go to the log, and its stdin to a file numbered after it
FAKE_SSH = """#!/bin/sh
n=$(($(wc -l < "$CALL_LOG" 2>/dev/null || echo 0) + 1))
echo "$*" >> "$CALL_LOG"
cat > "$CALL_DIR/sent.$n"
"""


def fail(why: str) -> None:
    sys.exit(f"[test] ERROR: ota-image scenario FAILED: {why}")


def run_ota(project: Path, *args: str) -> subprocess.CompletedProcess:
    fakebin = project / "bin"
    fakebin.mkdir(parents=True, exist_ok=True)
    (fakebin / "ssh").write_text(FAKE_SSH)
    (fakebin / "ssh").chmod(0o755)
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", CALL_LOG=str(project / "calls.log"),
               CALL_DIR=str(project), CUSTOM_HOSTNAME=HOSTNAME, ADDRESS=ADDRESS)
    return subprocess.run([BIN, "-C", str(project), "ota", *args], env=env, cwd=project.parent,
                          capture_output=True, text=True)


def ota(tmp: Path, name: str, image: Path, *args: str) -> None:
    """write `image` (gzip when named .gz) holding fresh data, send it with `args`, and check what arrived"""
    project = tmp / name
    data = os.urandom(IMAGE_BYTES)
    image = project / image
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(gzip.compress(data, 1) if image.suffix == ".gz" else data)
    done = run_ota(project, *args)
    if done.returncode:
        fail(f"{name}: ota exited with {done.returncode}:\n{done.stderr}")
    calls = (project / "calls.log").read_text().splitlines()
    if len(calls) != 2 or not all(c.startswith(f"root@{ADDRESS} ") for c in calls):
        fail(f"{name}: want two commands as root at {ADDRESS}, got {calls}")
    place = calls[0].split()[-1]
    if (project / "sent.1").read_bytes() != WRITER.read_bytes():
        fail(f"{name}: the device was not handed toolbox/ota-write first")
    if place not in calls[1].split():
        fail(f"{name}: the writer was left at {place}, and then not run: {calls[1]}")
    if gzip.decompress((project / "sent.2").read_bytes()) != data:
        fail(f"{name}: the writer was not sent the image as gzip")
    print(f"[test] {name}: ok", file=sys.stderr)


def missing(tmp: Path) -> None:
    project = tmp / "missing"
    done = run_ota(project)
    if not done.returncode or (project / "calls.log").exists():
        fail("missing: with no image built, the device was still reached")
    print("[test] missing: ok", file=sys.stderr)


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        ota(tmp, "default-gzip", Path(f"images/{HOSTNAME}.img.gz"))
        ota(tmp, "default-raw", Path(f"images/{HOSTNAME}.img"))
        ota(tmp, "named-gzip", Path("elsewhere/card.img.gz"), "elsewhere/card.img.gz")
        ota(tmp, "named-raw", Path("elsewhere/card.img"), "elsewhere/card.img")
        missing(tmp)
    print("[test] ota-image scenario PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
