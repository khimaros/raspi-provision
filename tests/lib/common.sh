#!/bin/bash
# shared configuration and helpers for the virtual test environment.
# sourced by the image/overlay/qemu libs and the scenario scripts.

[ -n "${_RASPI_TEST_COMMON:-}" ] && return 0
_RASPI_TEST_COMMON=1
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$COMMON_DIR/../.." && pwd)"
TESTS="$REPO/tests"
WORK="$TESTS/.work"

# upstream image to virtualize; overridable so the Makefile can pass its own value
IMAGE_RASPIOS="${IMAGE_RASPIOS:-$REPO/images/raspios-lite.img.xz}"

# work artifacts (all gitignored under tests/.work/)
WORK_SD="$WORK/sd.img"
KERNEL="$WORK/kernel8.img"
DTB="$WORK/bcm2711-rpi-4-b.dtb"
CMDLINE="$WORK/cmdline.txt"
CONSOLE_LOG="$WORK/console.log"
QEMU_PIDFILE="$WORK/qemu.pid"

# export these so the binary (run from the scenarios) bakes the same identity the
# assertions check, overriding any repo customize.env.
export CUSTOM_HOSTNAME="${CUSTOM_HOSTNAME:-elysium}"
export CUSTOM_USERNAME="${CUSTOM_USERNAME:-elysium}"
export CUSTOM_PASSWORD="${CUSTOM_PASSWORD:-elysium9}"
# the scenarios boot or inspect what they build, so they ask the binary for a raw
# image at this path in the project, rather than the gzip it writes by default.
RAW_IMAGE="images/$CUSTOM_HOSTNAME.img"
# baking depends adds a long qemu install to every build; only the bake-depends
# scenario turns it on.
export BAKE_DEPENDS="${BAKE_DEPENDS:-0}"

# the scenarios build images through the raspi-provision binary; prefer the debug
# build (what `make build` produces), falling back to the release build.
if [ -z "${BIN:-}" ]; then
  for cand in "$REPO/target/debug/raspi-provision" "$REPO/target/release/raspi-provision"; do
    [ -x "$cand" ] && { BIN="$cand"; break; }
  done
  : "${BIN:=$REPO/target/debug/raspi-provision}"
fi
need_binary() { [ -x "$BIN" ] || die "binary not built: $BIN (run: make build)"; }

# build $RAW_IMAGE via the binary. run from outside the repo so -C (not the cwd)
# is what locates the project.
build_image() {
  need_binary
  ( cd "$WORK" && "$BIN" -C "$REPO" image "$RAW_IMAGE" ) >&2
}

# first boot under TCG is slow and resizes the rootfs; give it room
BOOT_TIMEOUT="${BOOT_TIMEOUT:-1200}"

# markers emitted by the in-guest report service (tests/overlay/.../test-report)
REPORT_BEGIN="===TEST-REPORT-BEGIN==="
REPORT_END="===TEST-REPORT-END==="

# sbin holds losetup/mkfs.vfat, often absent from a non-root user's PATH
export PATH="$PATH:/usr/sbin:/sbin"

log()  { echo "[test] $*" >&2; }
warn() { echo "[test] WARNING: $*" >&2; }
die()  { echo "[test] ERROR: $*" >&2; exit 1; }

# the guest emits terminal escape sequences on the serial console (palette
# resets, cursor position queries); echoing them raw corrupts the invoking
# terminal. ESC[6n is the worst: the terminal answers it by typing a cursor
# report into the shell's input queue. strip CSI/OSC/other escapes and any
# remaining control characters (keeping tab) from console text before display.
strip_escapes() {
  # LC_ALL=C: the byte ranges below misbehave under UTF-8 locale collation.
  # OSC must strip before CSI: an unterminated OSC runs to the next escape,
  # and removing that escape first would let the OSC swallow following text.
  LC_ALL=C sed -E -e 's,\x1b\][^\x07\x1b]*\x07?,,g' \
         -e 's,\x1b\[[0-9;?]*[ -/]*[@-~],,g' \
         -e 's,\x1b[@-~],,g' \
         -e 's,[^[:print:]\t],,g'
}

mkdir -p "$WORK"
