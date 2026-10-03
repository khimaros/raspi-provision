#!/bin/bash
# usb host-mode test: attach an emulated usb mass-storage device with a sentinel to
# the Pi's (host-mode) dwc2 controller and assert the booted guest enumerates it and
# reads the sentinel -- i.e. the Pi works as a usb host. root-free: builds a plain
# image and boots the real artifact on qemu with the usb device attached.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/wait.sh"; source "$LIB/image-boot.sh"

USB_IMG="$WORK/usb-host.img"
SENTINEL="RASPI-USB-HOST-OK"

log "building plain image"
build_image   # usb host mode is independent of the root overlay shape
image_boot_prepare plain "$REPO/images/$CUSTOM_HOSTNAME.img"

log "building usb mass-storage image with sentinel"
rm -f "$USB_IMG"
truncate -s 32M "$USB_IMG"
mkfs.vfat -n USBHOST "$USB_IMG" >/dev/null
printf '%s\n' "$SENTINEL" | mcopy -i "$USB_IMG" - ::SENTINEL.TXT

start_qemu \
  -drive "file=$USB_IMG,format=raw,if=none,id=usbdisk" \
  -device usb-storage,drive=usbdisk
trap stop_qemu EXIT

if ! wait_for_marker "$CONSOLE_LOG" "$REPORT_END" "$BOOT_TIMEOUT"; then
  warn "no report within ${BOOT_TIMEOUT}s; last console output:"
  tail -n 40 "$CONSOLE_LOG" | strip_escapes >&2 || true
  die "usb-host scenario FAILED"
fi

report="$(report_block)"
echo "$report" >&2
grep -q "usb-content: $SENTINEL" <<<"$report" \
  || die "usb-host scenario FAILED: sentinel not read (host mode not working)"
log "usb-host scenario PASSED"
