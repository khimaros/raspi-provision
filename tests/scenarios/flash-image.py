#!/usr/bin/env python3
# device-free test of `raspi-provision flash`: a fake sudo on PATH runs dd for
# real against a plain file standing in for the card, and records the rest. the
# card must end up holding the image, whether it was gzip-compressed or raw, named
# on the command line or found under images/.

import gzip
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BIN = os.environ.get("BIN", str(REPO / "target/debug/raspi-provision"))
HOSTNAME = "flashtest"
# more than one dd block, ending in a partial one
IMAGE_BYTES = 5 * 1024 * 1024 + 512
FAKE_SUDO = '#!/bin/sh\necho "$*" >> "$CALL_LOG"\ncase "$1" in dd) exec "$@" ;; esac\n'


def fail(why: str) -> None:
    sys.exit(f"[test] ERROR: flash-image scenario FAILED: {why}")


def flash(tmp: Path, name: str, image: Path, *args: str) -> None:
    """write `image` (gzip when named .gz) holding fresh data, flash with `args`, and check the card"""
    project, fakebin, card = tmp / name, tmp / name / "bin", tmp / name / "card"
    data = os.urandom(IMAGE_BYTES)
    image = project / image
    for d in (fakebin, image.parent):
        d.mkdir(parents=True, exist_ok=True)
    (fakebin / "sudo").write_text(FAKE_SUDO)
    (fakebin / "sudo").chmod(0o755)
    image.write_bytes(gzip.compress(data, 1) if image.suffix == ".gz" else data)
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", CALL_LOG=str(project / "calls.log"),
               CUSTOM_HOSTNAME=HOSTNAME, MOUNT_DEVICE=str(card))
    done = subprocess.run([BIN, "-C", str(project), "flash", *args], env=env, cwd=tmp, capture_output=True, text=True)
    if done.returncode:
        fail(f"{name}: flash exited with {done.returncode}:\n{done.stderr}")
    if not card.exists() or card.read_bytes() != data:
        fail(f"{name}: the card does not hold the image")
    if "sync" not in (project / "calls.log").read_text().splitlines():
        fail(f"{name}: the card was not synced")
    print(f"[test] {name}: ok", file=sys.stderr)


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        flash(tmp, "default-gzip", Path(f"images/{HOSTNAME}.img.gz"))
        flash(tmp, "default-raw", Path(f"images/{HOSTNAME}.img"))
        flash(tmp, "named-gzip", Path("elsewhere/card.img.gz"), "elsewhere/card.img.gz")
        flash(tmp, "named-raw", Path("elsewhere/card.img"), "elsewhere/card.img")
    print("[test] flash-image scenario PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
