#!/usr/bin/env python3
# device-free test of `raspi-provision flash`: a fake sudo on PATH runs the writer
# for real against a plain file standing in for the card, and records the rest.
#
# a card with nothing to keep ends up holding the image, whether it was
# gzip-compressed or raw, named on the command line or found under images/.
#
# a card that already has a persist partition where the image puts its own keeps
# it: everything before it is the image's, the partition and its entry in the
# table are the card's, and the host keys saved for the device are left alone,
# since they are on that partition. --wipe, a persist somewhere else, and an image
# from before images knew what to do with a kept persist, all write the whole card.

import gzip
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests/lib"))
from cards import ENTRY, ENTRY_OFFSET, KEEP_MAGIC, PERSIST_START, SECTOR, image_data, table

BIN = os.environ.get("BIN", str(REPO / "target/debug/raspi-provision"))
HOSTNAME = "flashtest"
ADDRESS = "192.0.2.7"
# the card's own persist, grown since it was first flashed
GROWN_BYTES = 8 * 1024 * 1024
MOVED_START = PERSIST_START + 2048
FAKE_SUDO = '#!/bin/sh\necho "$*" >> "$CALL_LOG"\ncase "$1" in dd|bash|blkid) exec "$@" ;; esac\n'
# a stand-in, or the test would edit the known_hosts of whoever runs it
FAKE_KEYGEN = '#!/bin/sh\necho "$*" >> "$KEYGEN_LOG"\n'
# a card written whole comes up with new host keys, so the old ones are forgotten
# under every name the device answers to: its address, its name, the shared networks'
FORGOTTEN = {ADDRESS, HOSTNAME, f"{HOSTNAME}.local", "10.55.0.1", "10.55.1.1", "10.55.2.1"}


def fail(why: str) -> None:
    sys.exit(f"[test] ERROR: flash-image scenario FAILED: {why}")


def used_card(card: Path, start: int) -> None:
    """a card flashed before: other contents, and a persist filesystem at `start`"""
    card.write_bytes(table(b"", start, GROWN_BYTES // SECTOR) + os.urandom(start * SECTOR - SECTOR))
    with open(card, "ab") as handle:
        handle.truncate(start * SECTOR + GROWN_BYTES)
    subprocess.run(["mke2fs", "-q", "-F", "-t", "ext4", "-L", "persist", "-E", f"offset={start * SECTOR}", card,
                    f"{GROWN_BYTES // 1024}k"], check=True, env=dict(os.environ, PATH=os.environ["PATH"] + ":/usr/sbin"))


def flash(tmp: Path, name: str, image: Path, *args: str, data: bytes | None = None, persist: int | None = None) -> None:
    """flash `image` (gzip when named .gz) holding `data` with `args`, onto a
    fresh card or one with a persist partition at `persist`, and check the card"""
    project, fakebin, card = tmp / name, tmp / name / "bin", tmp / name / "card"
    data = data or image_data()
    image = project / image
    for d in (fakebin, image.parent):
        d.mkdir(parents=True, exist_ok=True)
    for command, body in (("sudo", FAKE_SUDO), ("ssh-keygen", FAKE_KEYGEN)):
        (fakebin / command).write_text(body)
        (fakebin / command).chmod(0o755)
    image.write_bytes(gzip.compress(data, 1) if image.suffix == ".gz" else data)
    if persist:
        used_card(card, persist)
    before = card.read_bytes() if persist else b""
    kept = persist == PERSIST_START and "--wipe" not in args and data.startswith(KEEP_MAGIC)
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}:/usr/sbin", CALL_LOG=str(project / "calls.log"),
               KEYGEN_LOG=str(project / "keygen.log"), CUSTOM_HOSTNAME=HOSTNAME, ADDRESS=ADDRESS, MOUNT_DEVICE=str(card))
    done = subprocess.run([BIN, "-C", str(project), "flash", *args], env=env, cwd=tmp, capture_output=True, text=True)
    if done.returncode:
        fail(f"{name}: flash exited with {done.returncode}:\n{done.stderr}")
    after = card.read_bytes() if card.exists() else b""
    if kept:
        check_kept(name, data, before, after)
    elif after[:len(data)] != data:
        fail(f"{name}: the card does not hold the image")
    if "sync" not in (project / "calls.log").read_text().splitlines():
        fail(f"{name}: the card was not synced")
    keygen = project / "keygen.log"
    forgotten = {line.removeprefix("-R ") for line in keygen.read_text().splitlines()} if keygen.exists() else set()
    if forgotten != (set() if kept else FORGOTTEN):
        fail(f"{name}: host keys forgotten for {sorted(forgotten)}, with persist {'kept' if kept else 'replaced'}")
    print(f"[test] {name}: ok", file=sys.stderr)


def check_kept(name: str, data: bytes, before: bytes, after: bytes) -> None:
    split, entry = PERSIST_START * SECTOR, slice(ENTRY_OFFSET, ENTRY_OFFSET + ENTRY.size)
    if after[split:] != before[split:]:
        fail(f"{name}: the persist partition was written to")
    if after[SECTOR:split] != data[SECTOR:split] or after[:ENTRY_OFFSET] != data[:ENTRY_OFFSET]:
        fail(f"{name}: what comes before persist is not the image's")
    if after[entry] != before[entry]:
        fail(f"{name}: persist's entry in the partition table is the fresh image's, too small for what it holds")


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        default = Path(f"images/{HOSTNAME}.img.gz")
        flash(tmp, "default-gzip", default)
        flash(tmp, "default-raw", Path(f"images/{HOSTNAME}.img"))
        flash(tmp, "named-gzip", Path("elsewhere/card.img.gz"), "elsewhere/card.img.gz")
        flash(tmp, "named-raw", Path("elsewhere/card.img"), "elsewhere/card.img")
        flash(tmp, "keep-gzip", default, persist=PERSIST_START)
        flash(tmp, "keep-raw", Path(f"images/{HOSTNAME}.img"), persist=PERSIST_START)
        flash(tmp, "wipe-asked", default, "--wipe", persist=PERSIST_START)
        flash(tmp, "wipe-moved", default, persist=MOVED_START)
        flash(tmp, "wipe-old-image", default, data=image_data(b""), persist=PERSIST_START)
    print("[test] flash-image scenario PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
