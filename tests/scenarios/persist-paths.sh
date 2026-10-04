#!/bin/bash
# root-free test that a downstream project can name more directories to keep on
# a tmpfs overlay image: build a throwaway project (via -C) whose overlay lists
# one in /etc/persist.d, write to it and beside it, cut the power, and assert
#   - the listed directory kept its file with no commit
#   - a directory beside it, not listed, lost its file
#   - a commit leaves the listed directory out, as it does the built-in state

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/image-boot.sh"

PROJECT="$WORK/persist-project"
KEEP=var/lib/keep
LOSE=var/lib/lose

log "building a tmpfs image for a project persisting /$KEEP"
need_binary
rm -rf "$PROJECT"
mkdir -p "$PROJECT/overlay/etc/persist.d"
printf '# kept across reboots\n/%s\n' "$KEEP" > "$PROJECT/overlay/etc/persist.d/test"
( cd "$WORK" && OVERLAY=tmpfs IMAGE_RASPIOS="$IMAGE_RASPIOS" "$BIN" -C "$PROJECT" image "$RAW_IMAGE" ) >&2
image_boot_prepare tmpfs "$PROJECT/$RAW_IMAGE" 1M
truncate -s 4294967296 "$WORK_SD"

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
drive() { python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT"; }

log "boot 1: write to the listed directory and to one beside it, then stage a commit"
start_qemu
out1="$(drive <<GUEST
for i in \$(seq 1 30); do [ "\$(systemctl is-active overlay-firstboot 2>/dev/null)" = activating ] || break; sleep 5; done
sudo mkdir -p /$LOSE
echo kept | sudo tee /$KEEP/file >/dev/null; echo "B1_KEEP=\$?"
echo lost | sudo tee /$LOSE/file >/dev/null
sudo overlay-commit --no-reboot >/dev/null
echo "B1_STAGED=\$(sudo test -e /persist/staging/data/$KEEP && echo yes || echo no)"
sudo rm -rf /persist/staging /persist/.commit-pending
sync
GUEST
)"
grep -aE '^B1_' <<<"$out1" >&2
qmp_quit; sleep 3

log "boot 2: only the listed directory kept its file"
start_qemu
out2="$(drive <<GUEST
echo "B2_KEEP=\$(cat /$KEEP/file 2>/dev/null)"
echo "B2_LOSE=\$(test -e /$LOSE/file && echo present || echo gone)"
GUEST
)"
grep -aE '^B2_' <<<"$out2" >&2
stop_qemu

f() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
fail=0
[ "$(f B1_KEEP "$out1")" = 0 ]      || { warn "boot1: /$KEEP was not there to write to"; fail=1; }
[ "$(f B1_STAGED "$out1")" = no ]   || { warn "a commit staged /$KEEP, which the state bind would hide"; fail=1; }
[ "$(f B2_KEEP "$out2")" = kept ]   || { warn "/$KEEP lost its file (got '$(f B2_KEEP "$out2")')"; fail=1; }
[ "$(f B2_LOSE "$out2")" = gone ]   || { warn "/$LOSE, not listed, kept its file"; fail=1; }
[ "$fail" -eq 0 ] || die "persist-paths scenario FAILED"
log "persist-paths scenario PASSED: a listed directory survives, its neighbour does not"
