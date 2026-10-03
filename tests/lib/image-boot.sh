#!/bin/bash
# root-free boot preparation for a built image -- plain or overlay (built by
# 'raspi-provision image'). works entirely through guestfish (no loop-mount, no
# sudo): on a work copy of the image it injects the report service, then extracts
# the qemu boot artifacts. an overlay image boots via the
# offline-patched initramfs the firmware would auto-load on hardware; a plain image
# boots its ext4 root directly with no initramfs. no privilege. sourced by the scenario.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/qemu.sh"

OVERLAY_INITRD="$WORK/overlay.initrd"
IMAGE_TEST_OVERLAY="$TESTS/image-e2e"

# image_boot_prepare <mode> <built-image> [grow]   mode = plain|persist|tmpfs
# copy the built image to the work sdcard, inject + enable the report service in
# its root, extract kernel/dtb/cmdline (+ initramfs for overlay), patch the dtb for
# qemu, and grow the card so the first-boot grow has room. sets/clears QEMU_INITRD.
image_boot_prepare() {
  local mode="$1" img="$2" grow="${3:-4G}"
  [ -f "$img" ] || die "built image not found: $img (run: make ... image)"
  command -v guestfish >/dev/null || die "guestfish not found (install libguestfs-tools)"

  log "copying $(basename "$img") to the work sdcard"
  cp "$img" "$WORK_SD"

  log "injecting report service and extracting boot artifacts (guestfish, no sudo)"
  guestfish -a "$WORK_SD" <<EOF
run
mount /dev/sda2 /
mkdir-p /usr/local/sbin
copy-in $IMAGE_TEST_OVERLAY/usr/local/sbin/image-report /usr/local/sbin
chmod 0755 /usr/local/sbin/image-report
chown 0 0 /usr/local/sbin/image-report
copy-in $IMAGE_TEST_OVERLAY/etc/systemd/system/image-report.service /etc/systemd/system
mkdir-p /etc/systemd/system/multi-user.target.wants
ln-s ../image-report.service /etc/systemd/system/multi-user.target.wants/image-report.service
umount-all
mount /dev/sda1 /
download /kernel8.img $KERNEL
download /bcm2711-rpi-4-b.dtb $DTB
download /cmdline.txt $CMDLINE
download /initramfs8 $OVERLAY_INITRD
EOF

  patch_dtb_for_qemu
  # qemu boots via -append, not the card cmdline; add the serial console it captures.
  printf '%s 8250.nr_uarts=1 console=ttyS0,115200\n' "$(cat "$CMDLINE")" > "$CMDLINE.tmp"
  mv "$CMDLINE.tmp" "$CMDLINE"

  if [ "$mode" = plain ]; then
    # a plain image boots its ext4 root directly. strip the stock 'resize' token:
    # qemu's -append is fixed, so the firstboot resize_early would never clear it
    # and would reboot-loop. (the systemd grow services still run; they are fine.)
    sed -E -i 's/(^| )resize( |$)/ /g; s/  */ /g' "$CMDLINE"
    unset QEMU_INITRD
  else
    export QEMU_INITRD="$OVERLAY_INITRD"
  fi

  log "growing work sdcard by $grow (headroom for first-boot grow)"
  truncate -s "+$grow" "$WORK_SD"
}
