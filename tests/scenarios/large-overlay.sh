#!/bin/bash
# root-free test that `raspi-provision image` makes room for a project overlay
# larger than the stock root's free space (e.g. container or vm images): build a
# throwaway downstream project (via -C) carrying one big file and assert it
# landed whole. the same project asks for kernel parameters of its own through
# CMDLINE_EXTRA. no boot: the image, built gzip-compressed as it is by default,
# is decompressed and inspected with guestfish.

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/common.sh"

PROJECT="$WORK/large-project"
PAYLOAD=opt/payload
# more than the stock root has free; sparse here, written out in full by the build.
PAYLOAD_BYTES=$((2 * 1024 * 1024 * 1024))
CMDLINE_EXTRA="psi=1 test.flag=on"

log "building a plain image for a project with a $((PAYLOAD_BYTES >> 20))MiB overlay file"
need_binary
rm -rf "$PROJECT"
mkdir -p "$PROJECT/overlay/$(dirname "$PAYLOAD")"
truncate -s "$PAYLOAD_BYTES" "$PROJECT/overlay/$PAYLOAD"
( cd "$WORK" && IMAGE_RASPIOS="$IMAGE_RASPIOS" CMDLINE_EXTRA="$CMDLINE_EXTRA" "$BIN" -C "$PROJECT" image ) >&2 \
  || die "large-overlay scenario FAILED (the image did not build)"

# built without a path, so the image is the gzip `flash` looks for
IMG="$WORK/large-overlay.img"
gzip -dc "$PROJECT/$RAW_IMAGE.gz" | cp --sparse=always /dev/stdin "$IMG" \
  || die "large-overlay scenario FAILED (no gzip image at $PROJECT/$RAW_IMAGE.gz)"
got="$(guestfish --ro -a "$IMG" run : mount-ro /dev/sda2 / : filesize "/$PAYLOAD")"
[ "$got" = "$PAYLOAD_BYTES" ] || die "large-overlay scenario FAILED (payload is $got bytes, want $PAYLOAD_BYTES)"
cmdline="$(guestfish --ro -a "$IMG" run : mount-ro /dev/sda1 / : cat /cmdline.txt)"
for tok in $CMDLINE_EXTRA; do
  grep -qw -- "$tok" <<<"$cmdline" || die "large-overlay scenario FAILED (no $tok in cmdline: $cmdline)"
done
log "large-overlay scenario PASSED"
