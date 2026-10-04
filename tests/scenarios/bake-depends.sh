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
# only in backports, which the project's overlay adds as an apt source: the
# build must resolve against the sources the device will have.
EXTRA_SUITE=trixie-backports
EXTRA_PKG=libglibutil1
# ships an initramfs hook, so installing it asks for an initramfs rebuild, which
# cannot work under the bake's boot and must not fail it.
HOOK_PKG=btrfs-progs

log "building a plain image for a project depending on $PKG and, from $EXTRA_SUITE, $EXTRA_PKG"
need_binary
rm -rf "$PROJECT"
mkdir -p "$PROJECT/depends" "$PROJECT/overlay/etc/apt/sources.list.d"
printf '%s\n' "$PKG" "$EXTRA_PKG" "$HOOK_PKG" > "$PROJECT/depends/test"
cat > "$PROJECT/overlay/etc/apt/sources.list.d/extra.sources" <<EOF
Types: deb
URIs: http://deb.debian.org/debian/
Suites: $EXTRA_SUITE
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
( cd "$WORK" && BAKE_DEPENDS=1 IMAGE_RASPIOS="$IMAGE_RASPIOS" "$BIN" -C "$PROJECT" image "$RAW_IMAGE" ) >&2
image_boot_prepare plain "$PROJECT/$RAW_IMAGE"

export QEMU_SERIAL_SOCK="$WORK/serial.sock" QEMU_QMP="$WORK/qmp.sock"
start_qemu
out="$(python3 "$LIB/serial.py" "$QEMU_SERIAL_SOCK" "$CUSTOM_USERNAME" "$CUSTOM_PASSWORD" "$BOOT_TIMEOUT" <<GUEST
for p in $PKG $EXTRA_PKG $HOOK_PKG vim; do echo "PKG_\$p=\$(dpkg-query -W -f='\${db:Status-Status}' \$p 2>/dev/null)"; done
echo "INITRAMFS_UPDATES=\$(sed -n 's/^update_initramfs=//p' /etc/initramfs-tools/update-initramfs.conf)"
echo "LEFTOVER=\$(test -e /var/cache/raspi-provision -o -e /usr/sbin/policy-rc.d && echo yes || echo no)"
GUEST
)"
grep -aE '^(PKG_|LEFTOVER|INITRAMFS_UPDATES)' <<<"$out" >&2
qmp_quit

f() { sed -n "s/^$1=//p" <<<"$out" | head -1; }
fail=0
[ "$(f "PKG_$PKG")" = installed ] || { warn "project package $PKG not installed"; fail=1; }
[ "$(f "PKG_$EXTRA_PKG")" = installed ] || { warn "$EXTRA_SUITE package $EXTRA_PKG not installed"; fail=1; }
[ "$(f "PKG_$HOOK_PKG")" = installed ] || { warn "initramfs hook package $HOOK_PKG not installed"; fail=1; }
[ "$(f INITRAMFS_UPDATES)" = yes ] || { warn "bake left initramfs updates switched off"; fail=1; }
[ "$(f PKG_vim)" = installed ]    || { warn "base package vim not installed"; fail=1; }
[ "$(f LEFTOVER)" = no ]          || { warn "bake left its debs or policy-rc.d in the image"; fail=1; }
[ "$fail" -eq 0 ] || die "bake-depends scenario FAILED"
log "bake-depends scenario PASSED"
