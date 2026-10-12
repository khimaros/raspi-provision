#!/usr/bin/env python3
# device-free test of `raspi-provision ota`: a fake ssh on PATH records each
# remote command and keeps what it was sent. the device must be handed the two
# scripts from toolbox/, then the image as gzip, whether it was built compressed
# or raw, named on the command line or found under images/. a truncated gzip
# stream fails on the device, which is why a raw image is compressed on the way.
#
# before any of that the device has to answer: one that has only just been asked
# to bring its network up, over usb say, is waited for, and one that never
# answers is sent nothing.
#
# a device whose card has a persist partition where the image puts its own keeps
# it, and the host keys saved for it with it, since that is where they are.
# --wipe, a card without one there, and an image from before images knew what to
# do with a kept persist, all replace the whole card.

import gzip
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests/lib"))
from cards import PERSIST_START, SECTOR, image_data

BIN = os.environ.get("BIN", str(REPO / "target/debug/raspi-provision"))
SCRIPTS = [REPO / "toolbox/write-image", REPO / "toolbox/ota-write"]
HOSTNAME = "otatest"
ADDRESS = "192.0.2.1"
# probes the device leaves unanswered before it is up, and the seconds `ota`
# is given to wait in these tests
LATE_PROBES = 2
NEVER = 1000
WAIT_SECONDS = 6
# what ssh says of a device it will not talk to, a changed host key for one
REFUSAL = "REMOTE HOST IDENTIFICATION HAS CHANGED"
# a command ending in `true` is a probe: it is counted, and fails while the
# device is down, saying why as ssh does. one that runs blkid asks what is on the
# card where the image's persist partition starts, and is told CARD_LABEL. each
# other call's arguments go to the log, and its stdin to a file numbered after it
FAKE_SSH = """#!/bin/sh
for last; do :; done
if [ "$last" = true ]; then
    echo "$*" >> "$PROBE_LOG"
    [ "$(wc -l < "$PROBE_LOG")" -gt "$DOWN_PROBES" ] && exit 0
    echo "$REFUSAL" >&2
    exit 255
fi
case "$*" in *"blkid -p"*)
    echo "$*" >> "$LABEL_LOG"
    echo "$CARD_LABEL"
    exit ;;
esac
n=$(($(wc -l < "$CALL_LOG" 2>/dev/null || echo 0) + 1))
echo "$*" >> "$CALL_LOG"
cat > "$CALL_DIR/sent.$n"
"""
# a stand-in, or the test would edit the known_hosts of whoever runs it
FAKE_KEYGEN = '#!/bin/sh\necho "$*" >> "$KEYGEN_LOG"\n'
# a device whose card was replaced whole restarts with new host keys. the old
# ones are forgotten under every name it answers to, and ssh is told to take a
# host it has no key for
FORGOTTEN = {ADDRESS, HOSTNAME, f"{HOSTNAME}.local", "10.55.0.1", "10.55.1.1", "10.55.2.1"}
ACCEPT_NEW = "StrictHostKeyChecking=accept-new"
PERSIST, NOTHING = "persist", ""


def forgotten(project: Path) -> set[str]:
    log = project / "keygen.log"
    return {line.removeprefix("-R ") for line in log.read_text().splitlines()} if log.exists() else set()


def fail(why: str) -> None:
    sys.exit(f"[test] ERROR: ota-image scenario FAILED: {why}")


def run_ota(project: Path, *args: str, down_probes: int = 0, label: str = NOTHING) -> subprocess.CompletedProcess:
    fakebin = project / "bin"
    fakebin.mkdir(parents=True, exist_ok=True)
    for command, body in (("ssh", FAKE_SSH), ("ssh-keygen", FAKE_KEYGEN)):
        (fakebin / command).write_text(body)
        (fakebin / command).chmod(0o755)
    env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", CALL_LOG=str(project / "calls.log"),
               KEYGEN_LOG=str(project / "keygen.log"), LABEL_LOG=str(project / "labels.log"), CARD_LABEL=label,
               CALL_DIR=str(project), PROBE_LOG=str(project / "probes.log"), DOWN_PROBES=str(down_probes),
               CUSTOM_HOSTNAME=HOSTNAME, ADDRESS=ADDRESS, OTA_WAIT_SECONDS=str(WAIT_SECONDS), REFUSAL=REFUSAL)
    return subprocess.run([BIN, "-C", str(project), "ota", *args], env=env, cwd=project.parent,
                          capture_output=True, text=True)


def build(project: Path, image: Path, data: bytes | None = None) -> bytes:
    """write `image` (gzip when named .gz) holding `data`, fresh unless given, and return it"""
    data = data or image_data()
    image = project / image
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(gzip.compress(data, 1) if image.suffix == ".gz" else data)
    return data


def ota(tmp: Path, name: str, image: Path, *args: str, down_probes: int = 0, label: str = NOTHING,
        data: bytes | None = None, kept: bool = False) -> None:
    """send `image` with `args` to a device whose card has `label` where the
    image's persist starts, and check what arrived"""
    project = tmp / name
    data = build(project, image, data)
    done = run_ota(project, *args, down_probes=down_probes, label=label)
    if done.returncode:
        fail(f"{name}: ota exited with {done.returncode}:\n{done.stderr}")
    calls = (project / "calls.log").read_text().splitlines()
    if len(calls) != 3 or not all(f"root@{ADDRESS} " in c for c in calls):
        fail(f"{name}: want three commands as root at {ADDRESS}, got {calls}")
    places = [call.split()[-1] for call in calls[:2]]
    for number, (script, place) in enumerate(zip(SCRIPTS, places), 1):
        if (project / f"sent.{number}").read_bytes() != script.read_bytes():
            fail(f"{name}: the device was not handed toolbox/{script.name}")
    mode = f"keep {PERSIST_START}" if kept else "wipe"
    if not calls[2].endswith(f" {places[1]} {places[0]} {mode}"):
        fail(f"{name}: want the writers at {places} run to {mode}, got: {calls[2]}")
    if gzip.decompress((project / "sent.3").read_bytes()) != data:
        fail(f"{name}: the writer was not sent the image as gzip")
    probes = (project / "probes.log").read_text().splitlines()
    if len(probes) != down_probes + 1:
        fail(f"{name}: want the device asked {down_probes + 1} times before it was sent anything, got {len(probes)}")
    asked = (project / "labels.log").read_text().splitlines() if (project / "labels.log").exists() else []
    if asked and f"-O {PERSIST_START * SECTOR} " not in asked[0]:
        fail(f"{name}: the card was not asked what is where the image's persist starts: {asked}")
    if not all(ACCEPT_NEW in line for line in calls + probes + asked):
        fail(f"{name}: a device with new host keys would not be let in: {calls + probes + asked}")
    if forgotten(project) != (set() if kept else FORGOTTEN):
        fail(f"{name}: host keys forgotten for {sorted(forgotten(project))}, with persist {mode}")
    print(f"[test] {name}: ok", file=sys.stderr)


def unsent(tmp: Path, name: str, image: Path | None, down_probes: int = 0) -> None:
    """nothing reaches a device with no image built, or one that never answers"""
    project = tmp / name
    if image:
        build(project, image)
    done = run_ota(project, down_probes=down_probes)
    if not done.returncode or (project / "calls.log").exists():
        fail(f"{name}: the device was still sent something")
    if forgotten(project):
        fail(f"{name}: host keys were forgotten for a device that was not flashed")
    if down_probes and REFUSAL not in done.stderr:
        fail(f"{name}: ssh's own reason was kept from the user:\n{done.stderr}")
    print(f"[test] {name}: ok", file=sys.stderr)


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        default, raw = Path(f"images/{HOSTNAME}.img.gz"), Path(f"images/{HOSTNAME}.img")
        ota(tmp, "default-gzip", default)
        ota(tmp, "default-raw", raw)
        ota(tmp, "named-gzip", Path("elsewhere/card.img.gz"), "elsewhere/card.img.gz")
        ota(tmp, "named-raw", Path("elsewhere/card.img"), "elsewhere/card.img")
        ota(tmp, "late", default, down_probes=LATE_PROBES)
        ota(tmp, "keep-gzip", default, label=PERSIST, kept=True)
        ota(tmp, "keep-raw", raw, label=PERSIST, kept=True)
        ota(tmp, "wipe-asked", default, "--wipe", label=PERSIST)
        ota(tmp, "wipe-old-image", default, label=PERSIST, data=image_data(b""))
        unsent(tmp, "missing", None)
        unsent(tmp, "absent", default, down_probes=NEVER)
    print("[test] ota-image scenario PASSED", file=sys.stderr)


if __name__ == "__main__":
    main()
