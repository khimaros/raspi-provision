# virtual test environment

builds the real Raspberry Pi OS arm64 image through the `raspi-provision` binary
and boots the artifact on QEMU's `raspi4b` machine, then asserts the result over
the serial console. fully root-free -- no loop-mount, no sudo. see
[../DESIGN.md](../DESIGN.md) for the architecture and fidelity tradeoffs.

## run

```
make test-e2e             # build + boot, assert provisioning (MODE=plain|persist|tmpfs)
make test-usb-host        # usb mass-storage enumeration (dwc2 host mode)
make test-factory-reset   # multi-boot: reset reverts the overlay upper
make test-update          # device-free: `update` command order via fake ssh/rsync
make test                 # standard suite: test-update + test-e2e (persist) + test-usb-host
make test-clean           # delete tests/.work/
```

config comes from `customize.env` / the Makefile defaults (hostname/user/password).

## what it covers

- **provisioning** (`test-e2e`): the built image boots with the right hostname and
  baked user (uid 1000 + sudo), the `shared-rndis` / `shared-ethernet` /
  `shared-hotspot` NM profiles load, swap/zram are off, and no units fail. for an
  overlay shape the root is `overlay` and persist grows online to fill the card.
- **usb-host**: an emulated usb mass-storage device on the Pi's dwc2 controller is
  enumerated and a sentinel read -- the Pi acting as a usb host.
- **factory-reset**: on a persist overlay, write a change + set the reset flag,
  reboot, and the initramfs reverts the overlay upper to the read-only base.
- **update**: `raspi-provision update` pushes the overlay, refreshes apt lists,
  installs base + project depends, then full-upgrades, in that order.

deferred (see [../ROADMAP.md](../ROADMAP.md)): usb gadget (`usb0` RNDIS) and the
wifi hotspot, neither of which stock QEMU can emulate.

## how it works

1. the scenario builds the provisioned image via `raspi-provision image`
   (libguestfs, unprivileged); `make test*` builds the binary first.
2. `lib/image-boot.sh` copies it to a work card, injects the in-guest report
   service, and extracts `kernel8.img` / the dtb / `cmdline.txt` (+ the patched
   initramfs for overlay images) for qemu.
3. `lib/qemu.sh` (`patch_dtb_for_qemu` + `start_qemu`) boots `raspi4b` with those,
   serial to `tests/.work/console.log`. multi-boot scenarios drive the console via
   `lib/serial.py` and flush between boots with `qmp_quit`.
4. the in-guest `image-report` service prints a report block to the console;
   single-boot scenarios poll the log for it and assert.

## debugging

- full boot transcript: `tests/.work/console.log`.
- no report / timeout usually means the serial console didn't attach. under qemu
  raspi4b the kernel console is the aux mini-uart (`ttyS0`, the second `-serial`),
  because bluetooth owns the PL011 (`ttyAMA0`); the harness sets
  `console=ttyS0,115200` (in `image-boot.sh`) and captures `serial_hd(1)` (in
  `lib/qemu.sh`).
- first boot is slow (TCG, no KVM on x86) and resizes the rootfs; raise
  `BOOT_TIMEOUT` (seconds), e.g. `BOOT_TIMEOUT=1800 make test`.
