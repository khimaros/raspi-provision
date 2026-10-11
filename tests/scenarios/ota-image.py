#!/usr/bin/env python3
# device-free test of `raspi-provision ota`: a fake ssh on PATH records each
# remote command and keeps what it was sent. the device must first be handed the
# writer from toolbox/, then the image as gzip, whether it was built compressed or
# raw, named on the command line or found under images/. a truncated gzip stream
# fails on the device, which is why a raw image is compressed on the way.
#
# before any of that the device has to answer: one that has only just been asked
# to bring its network up, over usb say, is waited for, and one that never
# answers is sent nothing.

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
# probes the device leaves unanswered before it is up, and the seconds `ota`
# is given to wait in these tests
LATE_PROBES = 2
NEVER = 1000
WAIT_SECONDS = 6
# a command ending in `true` is a probe: it is counted, and fails while the
# device is down. each other call's arguments go to the log, and its stdin to
# a file numbered after it
FAKE_SSH = """#!/bin/sh
for last; do :; done
if [ "$last" = true ]; then
    echo probe >> "$PROBE_LOG"
    [ "$(wc -l < "$PROBE_LOG")" -gt "$DOWN_PROBES" ]
    exit
fi
n=$(($(wc -l < "$CALL_LOG" 2>/dev/null || echo 0) + 1))
echo "$*" >> "$CALL_LOG"
cat > "$CALL_DIR/sent.$n"
"""


def fail(why: str) -> None:
    sys.exit(f"[test] ERROR: ota-image scenario FAILED: {why}")


def run_ota(project: Path, *args: str, down_probes: int = 0) -> subprocess.CompletedProcess:
    fakebin = project / "bin"
    fakebin.mkdir(parents=True, exist_ok=True)
    (fakebin / "ssh").write_text(FAKE_SSH)
    (fakebin / "ssh").chmod(0o755)
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", CALL_LOG=str(project / "calls.log"),
               CALL_DIR=str(project), PROBE_LOG=str(project / "probes.log"), DOWN_PROBES=str(down_probes),
               CUSTOM_HOSTNAME=HOSTNAME, ADDRESS=ADDRESS, OTA_WAIT_SECONDS=str(WAIT_SECONDS))
    return subprocess.run([BIN, "-C", str(project), "ota", *args], env=env, cwd=project.parent,
                          capture_output=True, text=True)


def build(project: Path, image: Path) -> bytes:
    """write `image` (gzip when named .gz) holding fresh data, and return the data"""
    data = os.urandom(IMAGE_BYTES)
    image = project / image
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(gzip.compress(data, 1) if image.suffix == ".gz" else data)
    return data


def ota(tmp: Path, name: str, image: Path, *args: str, down_probes: int = 0) -> None:
    """send a fresh `image` with `args`, and check what arrived"""
    project = tmp / name
    data = build(project, image)
    done = run_ota(project, *args, down_probes=down_probes)
    if done.returncode:
        fail(f"{name}: ota exited with {done.returncode}:\n{done.stderr}")
    calls = (project / "calls.log").read_text().splitlines()
    if len(calls) != 2 or not all(f"root@{ADDRESS} " in c for c in calls):
        fail(f"{name}: want two commands as root at {ADDRESS}, got {calls}")
    place = calls[0].split()[-1]
    if (project / "sent.1").read_bytes() != WRITER.read_bytes():
        fail(f"{name}: the device was not handed toolbox/ota-write first")
    if place not in calls[1].split():
        fail(f"{name}: the writer was left at {place}, and then not run: {calls[1]}")
    if gzip.decompress((project / "sent.2").read_bytes()) != data:
        fail(f"{name}: the writer was not sent the image as gzip")
    probes = len((project / "probes.log").read_text().splitlines())
    if probes != down_probes + 1:
        fail(f"{name}: want the device asked {down_probes + 1} times before it was sent anything, got {probes}")
    print(f"[test] {name}: ok", file=sys.stderr)


def unsent(tmp: Path, name: str, image: Path | None, down_probes: int = 0) -> None:
    """nothing reaches a device with no image built, or one that never answers"""
    project = tmp / name
    if image:
        build(project, image)
    done = run_ota(project, down_probes=down_probes)
    if not done.returncode or (project / "calls.log").exists():
        fail(f"{name}: the device was still sent something")
    print(f"[test] {name}: ok", file=sys.stderr)


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        default = Path(f"images/{HOSTNAME}.img.gz")
        ota(tmp, "default-gzip", default)
        ota(tmp, "default-raw", Path(f"images/{HOSTNAME}.img"))
        ota(tmp, "named-gzip", Path("elsewhere/card.img.gz"), "elsewhere/card.img.gz")
        ota(tmp, "named-raw", Path("elsewhere/card.img"), "elsewhere/card.img")
        ota(tmp, "late", default, down_probes=LATE_PROBES)
        unsent(tmp, "missing", None)
        unsent(tmp, "absent", default, down_probes=NEVER)
    print("[test] ota-image scenario PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
