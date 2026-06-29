#!/bin/bash
# launch the prepared image on qemu's raspi4b machine. sourced by scenarios.
#
# the serial console is written to a logfile; scenarios assert against the
# report block the in-guest service prints there. extra qemu args (e.g. a usb
# device for host-mode testing) are passed through to start_qemu.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

start_qemu() {
  for f in "$WORK_SD" "$KERNEL" "$DTB" "$CMDLINE"; do
    [ -f "$f" ] || die "image not prepared (missing $(basename "$f")); call image_boot_prepare first (e.g. via make test-e2e)"
  done
  stop_qemu
  : > "$CONSOLE_LOG"
  # qemu boots via -kernel/-append and bypasses the firmware, so config.txt's
  # initramfs directive is ignored; overlay-root scenarios pass the built
  # initramfs and cmdline flags explicitly via QEMU_INITRD / QEMU_APPEND_EXTRA.
  local initrd_args=() append; append="$(cat "$CMDLINE")"
  [ -n "${QEMU_INITRD:-}" ] && initrd_args+=(-initrd "$QEMU_INITRD")
  [ -n "${QEMU_APPEND_EXTRA:-}" ] && append="$append ${QEMU_APPEND_EXTRA}"
  # the raspios initramfs rpi_wd script hangs opening /dev/watchdog0 under
  # qemu (the bcm2835 watchdog start goes through the firmware mailbox, which
  # qemu only partially models); the script honors this opt-out token. the
  # kernel ignores it, so it is harmless on no-initramfs boots.
  append="$append watchdog_disarm=0"
  # the kernel console lands on the aux mini-uart (ttyS0 = serial_hd(1)); the PL011
  # (ttyAMA0 = serial_hd(0)) is owned by bluetooth. capture the second serial port,
  # leave the first unconnected. single-boot scenarios log it to a file and assert
  # against the report block; multi-boot scenarios (factory-reset, overlay-commit)
  # set QEMU_SERIAL_SOCK to drive it interactively (still logged) and QEMU_QMP to
  # flush+quit cleanly between boots.
  local serial_args qmp_args=()
  if [ -n "${QEMU_SERIAL_SOCK:-}" ]; then
    rm -f "$QEMU_SERIAL_SOCK"
    serial_args=(-chardev "socket,id=con,path=$QEMU_SERIAL_SOCK,server=on,wait=off,logfile=$CONSOLE_LOG" -serial null -serial chardev:con)
  else
    serial_args=(-serial null -serial "file:$CONSOLE_LOG")
  fi
  [ -n "${QEMU_QMP:-}" ] && { rm -f "$QEMU_QMP"; qmp_args=(-qmp "unix:$QEMU_QMP,server,nowait"); }
  log "booting qemu raspi4b (slow under TCG; up to ${BOOT_TIMEOUT}s) -> $CONSOLE_LOG"
  qemu-system-aarch64 \
    -machine raspi4b -cpu cortex-a72 -m 2G -smp 4 \
    -kernel "$KERNEL" -dtb "$DTB" "${initrd_args[@]}" \
    -drive "file=$WORK_SD,format=raw,if=sd" \
    -append "$append" \
    "${serial_args[@]}" "${qmp_args[@]}" -display none -monitor none \
    -pidfile "$QEMU_PIDFILE" -daemonize "$@"
}

# cleanly stop qemu, flushing block-device writes to the backing file, via QMP --
# the dtb-disabled watchdog HALTS on a guest reboot, so a multi-boot scenario runs
# two separate qemu boots over one card and must flush between them. needs QEMU_QMP.
qmp_quit() {
  if [ -n "${QEMU_QMP:-}" ]; then
    python3 - "$QEMU_QMP" <<'PY' 2>/dev/null || true
import socket,sys,time
try:
    q=socket.socket(socket.AF_UNIX); q.settimeout(5); q.connect(sys.argv[1]); time.sleep(0.3)
    q.recv(4096); q.send(b'{"execute":"qmp_capabilities"}\n'); time.sleep(0.2); q.recv(4096)
    q.send(b'{"execute":"quit"}\n'); time.sleep(0.3)
except Exception: pass
PY
    local pid; pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  fi
  stop_qemu
}

# qemu bypasses the firmware, so config.txt's dtoverlay handling never runs and
# the stock dtb is used verbatim. patch the extracted $DTB so the harness can use
# it: enable the usb controller with the upstream dwc2 host binding qemu models
# (the stock node is disabled with a legacy binding no mainline driver claims),
# and disable the watchdog node -- qemu 11's raspi4b resets the machine when the
# guest touches the WDOG register (systemd does early), reboot-looping every trixie
# boot. real hardware is unaffected (it uses the firmware dtb). see qemu gitlab
# #3260. drop the watchdog patch once a fixed qemu (>11.0) is the baseline.
patch_dtb_for_qemu() {
  fdtput -t s "$DTB" /soc/usb@7e980000 compatible snps,dwc2
  fdtput -t s "$DTB" /soc/usb@7e980000 dr_mode host
  fdtput -t s "$DTB" /soc/usb@7e980000 status okay
  fdtput -t s "$DTB" /soc/watchdog@7e100000 status disabled
}

stop_qemu() {
  [ -f "$QEMU_PIDFILE" ] || return 0
  local pid; pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "stopping qemu (pid $pid)"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$QEMU_PIDFILE"
}
