#!/bin/bash
# root-free factory-reset test on a persist overlay image: write a change, set the
# factory-reset flag, reboot, and assert the change was discarded -- the initramfs
# factory_reset reverts the overlay upper (persist) to the read-only base. the
# dtb-disabled watchdog HALTS on a guest reboot, so this runs two separate qemu
# boots over one card and flushes between them with QMP. no sudo, no loop-mount.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/image-boot.sh"

log "building persist image"
make -C "$REPO" OVERLAY=persist image >&2
image_boot_prepare persist "$REPO/images/$CUSTOM_HOSTNAME.img" 1M
truncate -s 4294967296 "$WORK_SD"   # 4 GiB (power of 2; small persist for a quick grow)

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
drive() { python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT"; }

log "boot 1: write a change to the persist upper + set the factory-reset flag"
start_qemu
out1="$(drive <<'GUEST'
for i in $(seq 1 30); do [ "$(systemctl is-active overlay-firstboot 2>/dev/null)" = activating ] || break; sleep 5; done
echo RESETME | sudo tee /etc/factory-test-marker >/dev/null
sudo touch /boot/firmware/factory-reset
sync
echo "B1_MARKER=$(cat /etc/factory-test-marker 2>/dev/null || echo none)"
echo "B1_FLAG=$(test -e /boot/firmware/factory-reset && echo set || echo missing)"
GUEST
)"
grep -aE '^B1_' <<<"$out1" >&2
qmp_quit; sleep 3

log "boot 2: factory_reset ran in the initramfs; verify the change is gone"
start_qemu
out2="$(drive <<'GUEST'
echo "B2_MARKER=$(cat /etc/factory-test-marker 2>/dev/null || echo GONE)"
echo "B2_FLAG=$(test -e /boot/firmware/factory-reset && echo STILL_SET || echo cleared)"
echo "B2_ROOT=$(findmnt -no FSTYPE /)"
GUEST
)"
grep -aE '^B2_' <<<"$out2" >&2
stop_qemu

f() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
fail=0
[ "$(f B1_MARKER "$out1")" = RESETME ]  || { warn "boot1: change not written";            fail=1; }
[ "$(f B1_FLAG   "$out1")" = set ]      || { warn "boot1: reset flag not set";             fail=1; }
[ "$(f B2_MARKER "$out2")" = GONE ]     || { warn "factory-reset did NOT discard the change (marker=$(f B2_MARKER "$out2"))"; fail=1; }
[ "$(f B2_FLAG   "$out2")" = cleared ]  || { warn "factory-reset flag not cleared";        fail=1; }
[ "$(f B2_ROOT   "$out2")" = overlay ]  || { warn "root not overlay after reset";          fail=1; }
[ "$fail" -eq 0 ] || die "factory-reset scenario FAILED"
log "factory-reset scenario PASSED: change discarded, flag cleared, overlay root intact"
