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
make test-overlay-commit  # multi-boot: tmpfs commit keeps opaque dirs, deletions, content
make test-kernel-update   # multi-boot: commit-gated kernel upgrade, backstop, reset
make test-bake-depends    # depends/ installed into the image at build time
make test-large-overlay   # an overlay larger than the stock root's free space
make test-persist-paths   # multi-boot: a directory listed in /etc/persist.d survives
make test-update          # device-free: `update` command order via fake ssh/rsync
make test-flash           # device-free: `flash` writes gzip and raw images via a fake sudo
make test-ota             # device-free: `ota` hands a device the writer, then the image, via a fake ssh
make test-ota-write       # multi-boot: the writer replaces the card a booted system runs from
make test                 # standard suite: test-update + test-flash + test-ota + test-e2e (persist) + test-usb-host
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
- **overlay-commit**: on tmpfs, replace a base directory, delete a base file and
  write a new one, commit, power-cycle: the fold keeps all three (the replaced
  directory's base entries stay hidden) and drops a later uncommitted change.
- **kernel-update**: on tmpfs, `dpkg -i` a newer rpi kernel (pinned debs fetched
  into `images/`) from a usb disk and commit. FAT must stay untouched until the
  commit; the next boot syncs the new kernel to FAT, and the harness then boots
  it from FAT with `overlay.ko` stripped from its initramfs (the backstop loads
  it from the committed layer). a factory reset restores the base kernel on FAT.
- **update**: `raspi-provision update` pushes the overlay, refreshes apt lists,
  installs base + project depends, then full-upgrades, in that order.
- **flash**: `raspi-provision flash` puts the image on the card byte for byte,
  from `images/<hostname>.img.gz`, a raw `.img` beside it, or a path it is given.
- **ota**: `raspi-provision ota` copies `toolbox/ota-write` to the device, then
  pipes it the image as gzip, compressing a raw one on the way.
- **ota-write**: on tmpfs, the writer is given a second image, one file apart,
  from a usb disk. it overwrites the card under the running system, and the
  next boot is the second image.
- **large-overlay**: an overlay bigger than the stock root lands whole, in the
  gzip image `raspi-provision image` writes when it is given no path.

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
