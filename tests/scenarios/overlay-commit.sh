#!/bin/bash
# root-free overlay-commit test on a tmpfs overlay image: make changes of every
# overlay-upper kind, commit, power-cycle, and assert the initramfs fold kept them.
#   - a replaced base directory (an opaque dir: base entries must stay hidden)
#   - a deleted base file (a whiteout)
#   - a new file's content (must not come back empty)
#   - an uncommitted change after the commit (must vanish)
#   - a NetworkManager connection made on the first boot (a persisted-state path:
#     must survive, not end up buried in the committed layer under the state bind)

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/image-boot.sh"

log "building tmpfs image"
OVERLAY=tmpfs build_image
image_boot_prepare tmpfs "$REPO/images/$CUSTOM_HOSTNAME.img" 1M
truncate -s 4294967296 "$WORK_SD"

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
drive() { python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT"; }

log "boot 1: change the root, commit without rebooting, then change it again"
start_qemu
out1="$(drive <<'GUEST'
for i in $(seq 1 30); do [ "$(systemctl is-active overlay-firstboot 2>/dev/null)" = activating ] || break; sleep 5; done
printf '[connection]\nid=firstboot\ntype=ethernet\n' | sudo tee /etc/NetworkManager/system-connections/firstboot.nmconnection >/dev/null
sudo rm -rf /etc/skel && sudo mkdir /etc/skel && echo fresh | sudo tee /etc/skel/only >/dev/null
sudo rm -f /etc/motd
sudo head -c 2097152 /dev/urandom | sudo tee /usr/local/bin/blob >/dev/null
echo "B1_BLOB=$(sha256sum /usr/local/bin/blob | cut -d' ' -f1)"
sudo overlay-commit --no-reboot >/dev/null; echo "B1_COMMIT=$?"
echo volatile | sudo tee /etc/uncommitted >/dev/null
GUEST
)"
grep -aE '^B1_' <<<"$out1" >&2
qmp_quit; sleep 3

log "boot 2: the fold ran in the initramfs; verify the committed state"
start_qemu
out2="$(drive <<'GUEST'
echo "B2_SKEL=$(ls -A /etc/skel | paste -sd, -)"
echo "B2_MOTD=$(test -e /etc/motd && echo present || echo gone)"
echo "B2_BLOB=$(sha256sum /usr/local/bin/blob 2>/dev/null | cut -d' ' -f1)"
echo "B2_UNCOMMITTED=$(test -e /etc/uncommitted && echo present || echo gone)"
echo "B2_NMCONN=$(test -e /etc/NetworkManager/system-connections/firstboot.nmconnection && echo present || echo missing)"
echo "B2_STAGING=$(test -e /persist/staging -o -e /persist/.commit-pending && echo left || echo clean)"
GUEST
)"
grep -aE '^B2_' <<<"$out2" >&2
stop_qemu

f() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
fail=0
[ "$(f B1_COMMIT "$out1")" = 0 ]          || { warn "boot1: overlay-commit failed"; fail=1; }
[ "$(f B2_SKEL "$out2")" = only ]         || { warn "replaced dir lost its opaque mark (skel=$(f B2_SKEL "$out2"))"; fail=1; }
[ "$(f B2_MOTD "$out2")" = gone ]         || { warn "deleted file came back"; fail=1; }
[ "$(f B2_BLOB "$out2")" = "$(f B1_BLOB "$out1")" ] || { warn "committed file content changed (blob=$(f B2_BLOB "$out2"))"; fail=1; }
[ "$(f B2_UNCOMMITTED "$out2")" = gone ]  || { warn "uncommitted change survived"; fail=1; }
[ "$(f B2_STAGING "$out2")" = clean ]     || { warn "fold left staging behind"; fail=1; }
[ "$(f B2_NMCONN "$out2")" = present ]    || { warn "first-boot NM connection lost (hidden under the state bind)"; fail=1; }
[ "$fail" -eq 0 ] || die "overlay-commit scenario FAILED"
log "overlay-commit scenario PASSED: opaque dir, whiteout, content, volatility"
