#!/bin/bash
# root-free kernel-update test on a tmpfs overlay image, the way `raspi-provision
# update` + overlay-commit lands a new kernel on a device:
#   boot 1  install a newer kernel deb from a usb disk, then commit (no reboot).
#           the FAT partition must be untouched: an uncommitted change is volatile.
#   boot 2  old kernel: the initramfs folds the commit, syncs the new kernel onto
#           FAT and reboots.
#   boot 3  new kernel from FAT, with overlay.ko stripped from its initramfs so the
#           backstop must load it from the committed layer. request a reset.
#   boot 4  the reset restores the base kernel onto FAT and reboots.
# qemu bypasses the firmware, so between boots the harness reads the kernel and
# initramfs the firmware would load straight off the card's FAT partition.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/wait.sh"; source "$LIB/image-boot.sh"

RPI_POOL="http://archive.raspberrypi.com/debian/pool/main/l/linux"
NEW_KVER="6.18.50+rpt-rpi-v8"
DEBS=(
  "linux-base-${NEW_KVER}_6.18.50-1+rpt1_arm64.deb f6b0870fde0785a392ca131f758280b07670837b31acf475e49f27c896583f85"
  "linux-image-${NEW_KVER}_6.18.50-1+rpt1_arm64.deb 8d44827fea22875e0f801252bdbc0f541c03144e970caafa3115bf485ff3c4bd"
)
SYNC_MARKER="boot firmware synced"
USB_IMG="$WORK/kernel-debs.img"
BASE="$WORK/fat-base" NEW="$WORK/fat-new" AFTER="$WORK/fat-reset"

# fetch the pinned kernel debs once into images/ (gitignored), verifying hashes.
debs=()
for d in "${DEBS[@]}"; do
  f="$REPO/images/${d%% *}"
  [ -f "$f" ] || curl -fsSL -o "$f" "$RPI_POOL/${d%% *}" || die "download failed: ${d%% *}"
  echo "${d##* }  $f" | sha256sum -c --quiet - || die "checksum mismatch: $f"
  debs+=("$f")
done

log "building tmpfs image"
OVERLAY=tmpfs build_image
image_boot_prepare tmpfs "$REPO/images/$CUSTOM_HOSTNAME.img" 1M
truncate -s 4294967296 "$WORK_SD"
usb_disk "$USB_IMG" KDEBS "${debs[@]}"
fat_get "$BASE" kernel8.img initramfs8

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock" SERIAL_SCRIPT_TIMEOUT=2400
drive() { python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT"; }
fail=0
same() { cmp -s "$1" "$2"; }
# boot_until_sync <label>: boot, wait for the initramfs firmware sync, then stop
# (the guest reboot halts qemu-raspi4b, so the harness power-cycles instead).
boot_until_sync() {
  start_qemu
  if ! wait_for_marker "$CONSOLE_LOG" "$SYNC_MARKER" "$BOOT_TIMEOUT"; then
    warn "$1: no '$SYNC_MARKER' within ${BOOT_TIMEOUT}s; last console output:"
    tail -n 40 "$CONSOLE_LOG" | strip_escapes >&2 || true
    fail=1
  fi
  sleep 5; qmp_quit
}

log "boot 1: install $NEW_KVER from usb, commit without rebooting"
start_qemu -drive "file=$USB_IMG,format=raw,if=none,id=usbdisk" -device usb-storage,drive=usbdisk
out1="$(drive <<'GUEST'
for i in $(seq 1 30); do [ "$(systemctl is-active overlay-firstboot 2>/dev/null)" = activating ] || break; sleep 5; done
sudo mount -o ro /dev/sda /mnt
sudo dpkg -i /mnt/*.deb > /tmp/dpkg.log 2>&1; echo "B1_DPKG=$?"
tail -n 5 /tmp/dpkg.log
echo "B1_MODULES=$(ls /usr/lib/modules | paste -sd, -)"
sudo umount /mnt
sudo overlay-commit --no-reboot >/dev/null; echo "B1_COMMIT=$?"
GUEST
)"
grep -aE '^B1_' <<<"$out1" >&2
qmp_quit; sleep 3
grep -q "^B1_DPKG=0" <<<"$out1" || { warn "boot1: kernel install failed"; fail=1; }
fat_get "$WORK/fat-b1" kernel8.img
same "$BASE/kernel8.img" "$WORK/fat-b1/kernel8.img" \
  || { warn "boot1: kernel install wrote FAT before any commit (uncommitted reboot would boot a kernel with no modules)"; fail=1; }

log "boot 2: old kernel folds the commit and syncs the new kernel onto FAT"
boot_until_sync "boot2"
fat_get "$NEW" kernel8.img initramfs8 bcm2711-rpi-4-b.dtb
same "$BASE/kernel8.img" "$NEW/kernel8.img" && { warn "boot2: FAT kernel8.img not updated after commit"; fail=1; }
ird="$WORK/ird-new"; rm -rf "$ird"; unmkinitramfs "$NEW/initramfs8" "$ird"
find "$ird" -name 'overlay.ko*' | grep -q . || { warn "new initramfs lacks overlay.ko"; fail=1; }
find "$ird" -path '*/scripts/overlay' | grep -q . || { warn "new initramfs lacks scripts/overlay"; fail=1; }
# strip overlay.ko so boot 3 exercises the backstop (load from the committed layer).
find "$ird" -name 'overlay.ko*' -delete
# unmkinitramfs puts a plain initramfs at the top, or under main/ after an early cpio.
root="$ird"; [ -f "$root/init" ] || root="$ird/main"
( cd "$root" && find . | cpio -o -H newc --quiet -R 0:0 ) > "$NEW/initramfs8.stripped"

log "boot 3: new kernel (overlay.ko only on persist); request a factory reset"
KERNEL="$NEW/kernel8.img" DTB="$NEW/bcm2711-rpi-4-b.dtb" QEMU_INITRD="$NEW/initramfs8.stripped"
patch_dtb_for_qemu
start_qemu
out3="$(drive <<'GUEST'
echo "B3_KERNEL=$(uname -r)"
echo "B3_ROOT=$(findmnt -no FSTYPE /)"
echo "B3_GETHER=$(lsmod | grep -q '^g_ether' && echo loaded || echo missing)"
sudo touch /boot/bootfs/factory-reset; sync
GUEST
)"
grep -aE '^B3_' <<<"$out3" >&2
qmp_quit; sleep 3
f() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
[ "$(f B3_KERNEL "$out3")" = "$NEW_KVER" ] || { warn "boot3: running $(f B3_KERNEL "$out3"), want $NEW_KVER"; fail=1; }
[ "$(f B3_ROOT "$out3")" = overlay ]       || { warn "boot3: root not overlay";                     fail=1; }
[ "$(f B3_GETHER "$out3")" = loaded ]      || { warn "boot3: new kernel modules did not load";       fail=1; }

log "boot 4: factory reset restores the base kernel onto FAT"
boot_until_sync "boot4"
fat_get "$AFTER" kernel8.img initramfs8
same "$BASE/kernel8.img" "$AFTER/kernel8.img" || { warn "boot4: reset did not restore kernel8.img"; fail=1; }
same "$BASE/initramfs8" "$AFTER/initramfs8"   || { warn "boot4: reset did not restore initramfs8"; fail=1; }

[ "$fail" -eq 0 ] || die "kernel-update scenario FAILED"
log "kernel-update scenario PASSED: commit-gated kernel update, backstop, reset restores base"
