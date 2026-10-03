#!/bin/bash
# root-free test that `raspi-provision image` installs depends/ packages at build
# time: build a throwaway downstream project (via -C) whose depends/ lists a
# package the base image lacks, boot it with no network, and assert both that
# package and a framework base package are installed.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/image-boot.sh"

PROJECT="$WORK/bake-project"
# pulls ~80 debs: more than one guestfish script command takes as arguments.
PKG=imagemagick

log "building a plain image for a project depending on $PKG"
need_binary
rm -rf "$PROJECT"
mkdir -p "$PROJECT/depends"
echo "$PKG" > "$PROJECT/depends/test"
( cd "$WORK" && BAKE_DEPENDS=1 IMAGE_RASPIOS="$IMAGE_RASPIOS" "$BIN" -C "$PROJECT" image ) >&2
image_boot_prepare plain "$PROJECT/images/$CUSTOM_HOSTNAME.img"

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
start_qemu
out="$(python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT" <<GUEST
for p in $PKG vim; do echo "PKG_\$p=\$(dpkg-query -W -f='\${db:Status-Status}' \$p 2>/dev/null)"; done
echo "LEFTOVER=\$(test -e /var/cache/raspi-provision -o -e /usr/sbin/policy-rc.d && echo yes || echo no)"
GUEST
)"
grep -aE '^(PKG_|LEFTOVER)' <<<"$out" >&2
qmp_quit

f() { sed -n "s/^$1=//p" <<<"$out" | head -1; }
fail=0
[ "$(f "PKG_$PKG")" = installed ] || { warn "project package $PKG not installed"; fail=1; }
[ "$(f PKG_vim)" = installed ]    || { warn "base package vim not installed"; fail=1; }
[ "$(f LEFTOVER)" = no ]          || { warn "bake left its debs or policy-rc.d in the image"; fail=1; }
[ "$fail" -eq 0 ] || die "bake-depends scenario FAILED"
log "bake-depends scenario PASSED"
