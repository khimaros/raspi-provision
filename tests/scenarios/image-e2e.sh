#!/bin/bash
# end-to-end test of an offline-built image: build it, boot the real artifact on
# qemu root-free (extract its boot bits via guestfish, no sudo), and assert it
# provisions correctly. modes:
#   plain   -- writable ext4 root, stock raspios first-boot grow (make image)
#   persist -- overlay root, all changes survive; persist grown online to fill card
#   tmpfs   -- overlay root, ephemeral; identity seeded onto persist
# usage: image-e2e.sh [plain|persist|tmpfs]   (default: persist)

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"; source "$LIB/qemu.sh"; source "$LIB/wait.sh"
source "$LIB/image-boot.sh"

MODE="${1:-persist}"
case "$MODE" in plain|persist|tmpfs) ;; *) die "usage: image-e2e.sh [plain|persist|tmpfs]" ;; esac
IMG="$REPO/images/$CUSTOM_HOSTNAME.img"

log "building image (mode=$MODE)"
if [ "$MODE" = plain ]; then
  make -C "$REPO" image >&2
else
  make -C "$REPO" OVERLAY="$MODE" image >&2
fi

image_boot_prepare "$MODE" "$IMG"
start_qemu
trap stop_qemu EXIT

if ! wait_for_marker "$CONSOLE_LOG" "$REPORT_END" "$BOOT_TIMEOUT"; then
  warn "no report within ${BOOT_TIMEOUT}s; last console output:"
  tail -n 40 "$CONSOLE_LOG" | strip_escapes >&2 || true
  die "image-e2e scenario FAILED ($MODE)"
fi

report="$(report_block)"
echo "$report" >&2

field() { sed -n "s/^$1: //p" <<<"$report" | head -1; }
fail=0
chk() {
  local key="$1" want="$2" got; got="$(field "$key")"
  [ "$got" = "$want" ] || { warn "$key: got '$got' want '$want'"; fail=1; }
}

# provisioning + today's clean-boot fixes -- the same for every mode. the user is
# renamed onto the stock uid-1000 template and gets a real shell + sudo; the stock
# first-boot wizard and redundant networkd are masked and the ssh banner is gone.
chk hostname "$CUSTOM_HOSTNAME"
chk user-uid 1000
chk user-shell /bin/bash
chk user-sudo yes
chk sshd active
chk networkd inactive
chk userconfig inactive
chk ssh-banner none
chk swap-active none
chk zram-device none
for c in shared-rndis shared-ethernet shared-hotspot; do
  grep -q "$c" <<<"$(field nm-conns)" || { warn "missing NM connection: $c"; fail=1; }
done
# only qemu hardware-absence failures are tolerated (no eeprom, no wifi radio); on
# real hardware these units succeed. anything else is a real regression.
for u in $(field failed-units | tr ',' ' '); do
  case "$u" in
    ""|rpi-eeprom-update.service|iw-dev-wlan1.service) ;;
    *) warn "unexpected failed unit: $u"; fail=1 ;;
  esac
done

if [ "$MODE" = plain ]; then
  # plain keeps a normal writable root and the stock raspios resize; no overlay,
  # no persist partition.
  chk root-fstype ext4
  [ -z "$(field overlay-upper)" ]  || { warn "plain image carries overlay-upper=$(field overlay-upper)"; fail=1; }
  [ -z "$(field persist-fstype)" ] || { warn "plain image has a persist fs: $(field persist-fstype)"; fail=1; }
  log "plain checks: ext4 root, no overlay, no persist"
else
  # overlay root with the requested upper shape; first-boot grow filled persist
  # (the image ships persist small to stay sparse).
  chk root-fstype overlay
  chk overlay-upper "$MODE"
  chk overlay-firstboot active
  chk persist-fstype ext4
  psz="$(field persist-size-mb)"
  if ! { [ -n "$psz" ] && [ "$psz" -gt 1000 ] 2>/dev/null; }; then
    warn "persist-size-mb: got '$psz' want >1000 (first-boot grow failed?)"; fail=1
  fi
  log "overlay checks: overlay root, upper=$MODE, persist grew to ${psz}MB"
fi

[ "$fail" -eq 0 ] || die "image-e2e scenario FAILED ($MODE)"
log "image-e2e scenario PASSED ($MODE)"
