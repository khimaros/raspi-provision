#!/bin/bash
# root-free test of toolbox/ota-write and toolbox/write-image, the half of
# `raspi-provision ota` that runs on the device: boot a tmpfs overlay image, hand
# the writer a second image that differs by one file, and assert the card boots
# that one afterwards. the writer overwrites the card the system is running from,
# which only a real boot can show to work. the second image and the writers come
# in on a usb disk, standing in for ssh. the dtb-disabled watchdog HALTS on a
# guest reboot, so the restart is a second qemu boot over the same card.
#
#   ota-write.sh [keep|wipe]    (default: keep)
#
# keep, as `ota` does by default: the persist partition stays. a file in the
# user's home and the ssh host key are the same after, and a system change the old
# image had staged for commit is NOT carried over to the new root (the initramfs
# adopts the partition: scripts/overlay, adopt_persist).
# wipe, as `ota --wipe`: home and the host key start over.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/wait.sh"; source "$LIB/image-boot.sh"

MODE="${1:-keep}"
case "$MODE" in keep|wipe) ;; *) die "usage: ota-write.sh [keep|wipe]" ;; esac
NEXT="$WORK/ota-next.img"
USB_IMG="$WORK/ota-usb.img"
USB_LABEL=OTA
# room on the usb disk beside the image, for the writers and the filesystem
USB_SLACK_MIB=64
MARKER=/etc/ota-marker
# a change to the system under the first image, staged for a commit
STALE=/etc/ota-stale
# in the user's home, which is on the persist partition
KEPT=ota-kept
HOST_KEY=/etc/ssh/ssh_host_ed25519_key.pub
FIRST="$WORK/ota-first-boot.log"
# more than persist is in any fresh image (128 MiB unless a project asks)
GROWN_MB=512
WRITTEN="ota: written"
# a program with a device mapped, as one that draws has the gpu's: the writer
# reads what programs have mapped into memory, and a device has no end to read to
MAPS_A_DEVICE="import mmap, time; device = open('/dev/zero', 'rb'); held = mmap.mmap(device.fileno(), 4096, mmap.MAP_PRIVATE, mmap.PROT_READ); time.sleep(86400)"
# for the guest to print the marker and reach its restart before qemu is stopped
SETTLE=10
# seconds, on top of the boot, for the write: qemu's card took 3 GB at 2.4 MB/s
WRITE_TIMEOUT="${WRITE_TIMEOUT:-3600}"

log "building tmpfs image"
OVERLAY=tmpfs build_image
image_boot_prepare tmpfs "$REPO/$RAW_IMAGE" 1M
truncate -s 4294967296 "$WORK_SD"

log "making the image to send: the same, under another name, plus $MARKER"
cp --sparse=always "$REPO/$RAW_IMAGE" "$NEXT"
guestfish -a "$NEXT" run : mount /dev/sda2 / : write "$MARKER" "next" : write /etc/raspi-provision-image-id "next"
persist_start="$(sfdisk -d "$NEXT" | sed -n 's/.*img3 : start= *\([0-9]*\).*/\1/p')"
[ -n "$persist_start" ] || die "the image has no third partition"
if [ "$MODE" = keep ]; then arguments="keep $persist_start"; else arguments=wipe; fi
gzip -1 -f "$NEXT"
rm -f "$USB_IMG"
truncate -s "$(( $(stat -c %s "$NEXT.gz") / 1048576 + USB_SLACK_MIB ))M" "$USB_IMG"
mkfs.vfat -F 32 -n "$USB_LABEL" "$USB_IMG" >/dev/null
mcopy -i "$USB_IMG" "$NEXT.gz" ::next.img.gz
mcopy -i "$USB_IMG" "$REPO/toolbox/ota-write" ::ota-write
mcopy -i "$USB_IMG" "$REPO/toolbox/write-image" ::write-image

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
drive() { python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT"; }

log "boot 1: leave a file at home and a staged change, then write the next image over the running card ($arguments)"
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
echo "B1_KEY=\$(cut -d' ' -f2 $HOST_KEY)"
echo kept > ~/$KEPT
nohup python3 -c "$MAPS_A_DEVICE" > /dev/null 2>&1 &
echo stale | sudo tee $STALE > /dev/null
sudo overlay-commit --no-reboot > /dev/null
echo "B1_STAGED=\$(sudo test -e /persist/staging/data$STALE && echo yes || echo no)"
sudo mount -o ro LABEL=$USB_LABEL /mnt
sudo cp /mnt/ota-write /mnt/write-image /run/
sudo dd if=/mnt/next.img.gz iflag=direct bs=1M status=none | sudo bash /run/ota-write /run/write-image $arguments
GUEST
if ! wait_for_marker "$CONSOLE_LOG" "$WRITTEN" "$((BOOT_TIMEOUT + WRITE_TIMEOUT))"; then
  warn "the writer never reported the card written; last console output:"
  tail -n 40 "$CONSOLE_LOG" | strip_escapes >&2 || true
  die "ota-write scenario FAILED"
fi
# the console log starts over with the next boot
strip_escapes < "$CONSOLE_LOG" | grep -aE '^B1_' > "$FIRST" || true
cat "$FIRST" >&2
sleep "$SETTLE"
qmp_quit; sleep 3

log "boot 2: the card now holds the next image"
start_qemu
out2="$(drive <<GUEST
echo "B2_MARKER=\$(cat $MARKER 2>/dev/null || echo none)"
echo "B2_ROOT=\$(findmnt -no FSTYPE /)"
echo "B2_HOSTNAME=\$(hostname)"
echo "B2_KEY=\$(cut -d' ' -f2 $HOST_KEY)"
echo "B2_KEPT=\$(cat ~/$KEPT 2>/dev/null || echo gone)"
echo "B2_STALE=\$(test -e $STALE && echo present || echo gone)"
echo "B2_PERSIST_MB=\$(df -m --output=size /persist | tail -1 | tr -d ' ')"
GUEST
)"
grep -aE '^B2_' <<<"$out2" >&2
stop_qemu

f() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
first="$(cat "$FIRST")"
fail=0
[ "$(f B1_MARKER "$first")" = none ]                || { warn "the first image already had $MARKER"; fail=1; }
[ "$(f B1_STAGED "$first")" = yes ]                 || { warn "boot 1 staged no change for the new root to refuse"; fail=1; }
[ "$(f B2_MARKER "$out2")" = next ]                 || { warn "the card did not boot the image it was sent"; fail=1; }
[ "$(f B2_ROOT "$out2")" = overlay ]                || { warn "root not overlay after the write"; fail=1; }
[ "$(f B2_HOSTNAME "$out2")" = "$CUSTOM_HOSTNAME" ] || { warn "hostname wrong after the write"; fail=1; }
[ "$(f B2_STALE "$out2")" = gone ]                  || { warn "a change made to the old system came back over the new one"; fail=1; }
if [ "$MODE" = keep ]; then
  [ "$(f B2_KEPT "$out2")" = kept ]                         || { warn "the file at home did not survive"; fail=1; }
  [ "$(f B2_KEY "$out2")" = "$(f B1_KEY "$first")" ]        || { warn "the ssh host key changed, though persist was kept"; fail=1; }
  # grown to the 4 GiB card on the first boot, and still so: the table's entry
  # for it was not replaced by the fresh image's small one
  [ "$(f B2_PERSIST_MB "$out2")" -gt "$GROWN_MB" ] || { warn "persist is back to its size in a fresh image"; fail=1; }
else
  [ "$(f B2_KEPT "$out2")" = gone ]                         || { warn "the file at home survived a wipe"; fail=1; }
  [ "$(f B2_KEY "$out2")" != "$(f B1_KEY "$first")" ]       || { warn "the ssh host key survived a wipe"; fail=1; }
fi
[ "$fail" -eq 0 ] || die "ota-write scenario FAILED ($MODE)"
log "ota-write scenario PASSED ($MODE): the running card was replaced and boots the image sent"
