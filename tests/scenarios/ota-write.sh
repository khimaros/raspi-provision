#!/bin/bash
# root-free test of toolbox/ota-write, the half of `raspi-provision ota` that runs
# on the device: boot a tmpfs overlay image, hand the writer a second image that
# differs by one file, and assert the card boots that one afterwards. the writer
# overwrites the card the system is running from, which only a real boot can show
# to work. the second image and the writer come in on a usb disk, standing in for
# ssh. the dtb-disabled watchdog HALTS on a guest reboot, so the restart is a
# second qemu boot over the same card.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/wait.sh"; source "$LIB/image-boot.sh"

NEXT="$WORK/ota-next.img"
USB_IMG="$WORK/ota-usb.img"
USB_LABEL=OTA
# room on the usb disk beside the image, for the writer and the filesystem
USB_SLACK_MIB=64
MARKER=/etc/ota-marker
WRITTEN="ota: written"
# for the guest to print the marker and reach its restart before qemu is stopped
SETTLE=10
# seconds, on top of the boot, for the write: qemu's card took 3 GB at 2.4 MB/s
WRITE_TIMEOUT="${WRITE_TIMEOUT:-3600}"

log "building tmpfs image"
OVERLAY=tmpfs build_image
image_boot_prepare tmpfs "$REPO/$RAW_IMAGE" 1M
truncate -s 4294967296 "$WORK_SD"

log "making the image to send: the same, plus $MARKER"
cp --sparse=always "$REPO/$RAW_IMAGE" "$NEXT"
guestfish -a "$NEXT" run : mount /dev/sda2 / : write "$MARKER" "next"
gzip -1 -f "$NEXT"
rm -f "$USB_IMG"
truncate -s "$(( $(stat -c %s "$NEXT.gz") / 1048576 + USB_SLACK_MIB ))M" "$USB_IMG"
mkfs.vfat -F 32 -n "$USB_LABEL" "$USB_IMG" >/dev/null
mcopy -i "$USB_IMG" "$NEXT.gz" ::next.img.gz
mcopy -i "$USB_IMG" "$REPO/toolbox/ota-write" ::ota-write

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
drive() { python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT"; }

log "boot 1: write the next image over the running card"
start_qemu \
  -drive "file=$USB_IMG,format=raw,if=none,id=usbdisk" \
  -device usb-storage,drive=usbdisk
trap stop_qemu EXIT
# the guest restarts under the script, so the console never reports it done.
# read past the page cache: a cached image would crowd out what the writer keeps
# in memory to go on running, which a stream from ssh never does
drive >/dev/null <<GUEST &
for i in \$(seq 1 30); do [ "\$(systemctl is-active overlay-firstboot 2>/dev/null)" = activating ] || break; sleep 5; done
echo "B1_MARKER=\$(cat $MARKER 2>/dev/null || echo none)"
sudo mount -o ro LABEL=$USB_LABEL /mnt
sudo cp /mnt/ota-write /run/ota-write
sudo dd if=/mnt/next.img.gz iflag=direct bs=1M status=none | sudo bash /run/ota-write
GUEST
if ! wait_for_marker "$CONSOLE_LOG" "$WRITTEN" "$((BOOT_TIMEOUT + WRITE_TIMEOUT))"; then
  warn "the writer never reported the card written; last console output:"
  tail -n 40 "$CONSOLE_LOG" | strip_escapes >&2 || true
  die "ota-write scenario FAILED"
fi
grep -q "B1_MARKER=none" "$CONSOLE_LOG" || die "ota-write scenario FAILED: the first image already had $MARKER"
sleep "$SETTLE"
qmp_quit; sleep 3

log "boot 2: the card now holds the next image"
start_qemu
out2="$(drive <<GUEST
echo "B2_MARKER=\$(cat $MARKER 2>/dev/null || echo none)"
echo "B2_ROOT=\$(findmnt -no FSTYPE /)"
echo "B2_HOSTNAME=\$(hostname)"
GUEST
)"
grep -aE '^B2_' <<<"$out2" >&2
stop_qemu

f() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
fail=0
[ "$(f B2_MARKER "$out2")" = next ]                 || { warn "the card did not boot the image it was sent"; fail=1; }
[ "$(f B2_ROOT "$out2")" = overlay ]                || { warn "root not overlay after the write"; fail=1; }
[ "$(f B2_HOSTNAME "$out2")" = "$CUSTOM_HOSTNAME" ] || { warn "hostname wrong after the write"; fail=1; }
[ "$fail" -eq 0 ] || die "ota-write scenario FAILED"
log "ota-write scenario PASSED: the running card was replaced and boots the image sent"
