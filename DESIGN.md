# DESIGN

## provisioning

`raspi-provision` overlays configuration onto an unmodified Raspberry Pi OS
image rather than building a custom image. configuration lives in a single
`overlay/` tree in runtime paths: files under `overlay/boot/firmware/` go to the
FAT firmware partition, everything else to the ext4 root.

`raspi-provision` is a rust binary (`src/`) that embeds the framework tree
(`overlay/`, `depends/`, `toolbox/`, `tests/`) at compile time and is a thin
launcher over the bash/guestfish engine in `toolbox/build-image`. `image` extracts
the embedded tree, sets `OVERLAY_LAYERS` to the bundled base plus the current
project's `./overlay` (later layers win), and execs `build-image`, which lays the
merged tree onto a copy of the upstream image offline and unprivileged
(libguestfs/guestfish, no loop-mount and no sudo): it mounts the FAT partition at
`boot/firmware` and tars the whole tree in so each file lands on the right
partition, and bakes the per-device bits (hostname/user/password/hotspot) from the
`CUSTOM_*` vars. the working tree is left untouched. a downstream project supplies
its own `overlay/` + `depends/` + `customize.env` and reuses the same binary, so
the framework stays a dependency rather than a fork.

`depends/` packages (base + project) are installed at build time by
`toolbox/bake-depends`, before the overlay is applied. maintainer scripts are
arm64 and a root-free build cannot chroot, so the work splits in two:

- the host's `apt-get` resolves and downloads, driven entirely by `APT_CONFIG`
  pointing at a copy of the image's own sources, keyrings and dpkg status (so it
  fetches only what the image lacks, at arm64). lists and debs persist in
  `images/.apt-cache` and `autoclean` bounds the cache. apt's simulated
  transaction is its exact plan (unpack/configure steps in dependency order):
  it selects this build's debs from the cache and becomes a dpkg script.
- the root partition grows by the debs' installed size plus margin (still the
  last partition, before persist is carved), the debs go in as one tarball
  (guestfish script commands cap at ~64 arguments), and the image boots once
  under qemu raspi4b with `init=` a throwaway script that replays the plan with
  the image's `dpkg`, then `dpkg --configure -a` (a `policy-rc.d` keeps services
  from starting), remounts root read-only and powers off. the guest's own apt is
  not used: with the image's package lists it prefers fetching a repo copy over
  a local deb of the same version. the host
  waits for its console marker. qemu bypasses the firmware, so the image's kernel
  and dtb are passed directly, with the dtb's watchdog disabled (see fidelity
  tradeoffs).

`BAKE_DEPENDS=0` skips this; `update` then installs them on the device.

connectivity is provided by three NetworkManager `shared` connections, each on
its own subnet so they can coexist:

- `shared-rndis`   (usb0)  10.55.0.1/24 -- USB gadget, default first-boot path
- `shared-ethernet` (eth)  10.55.1.1/24
- `shared-hotspot` (wlan1) 10.55.2.1/24 -- AP interface added from wlan0

the USB gadget is brought up by loading `dwc2,g_ether` from the kernel cmdline.
the hotspot uses a second virtual interface created from wlan0 by
`iw-dev-wlan1.service`.

## resilience to power loss

the sdcard root corrupts when writes are in flight as the power rail drops, and
flash wears with write volume. the defense is two complementary layers.

### phase 1: reduce writes (implemented)

applied unconditionally, independent of the read-only root:

- journald `Storage=volatile` -- the journal lives in `/run` (RAM), not the sdcard
- `noatime` on the root mount (already the stock raspios fstab default; not set
  via `rootflags=`, which the no-initramfs boot path rejects)
- swap and zram disabled entirely. trixie's default `zram+file` swap keeps a
  `/var/swap` writeback file -- a flash writer, and ~150-230MB of RAM under the
  tmpfs overlay root -- and a light appliance with ample RAM does not need swap;
  without it, memory pressure fails fast (oom) instead of thrashing. trixie layers
  swap in three places, so disabling it takes three overrides under `overlay/`:
  `etc/rpi/swap.conf.d/99-no-swap.conf` (`Mechanism=none` -- turns off rpi-swap and
  removes `/var/swap`), `etc/systemd/zram-generator.conf` (no `[zram0]` -- no zram
  swap setup), and `etc/modules-load.d/20-zram-generator.conf` (empty -- stops the
  force-load of the zram module that otherwise creates an unused `/dev/zram0`). (the
  older `dphys-swapfile.service -> /dev/null` mask targeted a mechanism trixie no
  longer uses, so it never actually disabled swap; kept as a harmless backstop.)
- `apt-daily*` and `man-db` periodic timers masked, so the box only writes when
  `raspi-provision update` pushes changes. `fstrim` is left enabled (aids flash health)

mask symlinks ship in `overlay/etc/systemd/system/` and are laid down at build time.

### phase 2: read-only root + persistent partition (implemented)

root mounts read-only under an overlayfs. this follows the same mechanism
`raspi-config` (`enable_overlayfs`) uses, reproduced offline where possible:

- an initramfs premount script at `/etc/initramfs-tools/scripts/overlay`
  mounts the real root read-only at `/lower`, mounts an upper, and stacks them
  as `overlay` on the real root mount. `overlay` is listed in
  `/etc/initramfs-tools/modules` so any initramfs regenerated on device (a kernel
  update) carries `overlay.ko`. these two files are static and ship in
  `overlay/`. the stock initramfs lacks the module, so the premount falls back to
  the base root's module tree, then to the writable layer's (after a committed
  kernel update the running kernel's modules exist only there).
- on the FAT firmware partition, `config.txt` gets `initramfs initrd.img-<KERN>-overlay`
  and `cmdline.txt` is prefixed with `boot=overlay`.
- the initramfs is kernel-version-bound. rather than rebuild it on device, the
  offline build patches the stock initramfs in place: it adds only
  `/scripts/overlay` and reuses the stock kernel modules, so no rebuild is needed
  and the first boot comes up overlay directly (see provisioning, above).
- a conf.d drop-in sets `MODULES=most` (the debian default; stock raspios uses
  `dep`). dep mode resolves the running root device, which fails when the
  kernel mounted root without an initramfs (`/proc/mounts` shows `/dev/root`,
  as under the qemu harness), and most keeps the built initramfs portable.

it is baked into the image by `raspi-provision image` with `OVERLAY` set (via
`toolbox/build-image`), which provisions the stock image unprivileged with
libguestfs (`guestfish`) -- no loop-mount, no sudo. it carves the persist
partition offline, applies the `overlay/` tree, and bakes the user offline
(renaming the stock uid-1000 template user). because the
user is pre-baked, it also finalizes the first-boot user setup the way raspios'
`cancel-rename` would -- masking `userconfig.service` (which otherwise hangs at a
`whiptail` username prompt on tty8, blocking `multi-user.target`) and dropping the
ssh "set up a valid user" banner -- and masks the redundant `systemd-networkd`
(raspios ships it alongside NetworkManager, which owns our interfaces, so
`networkd-wait-online` only times out and reports `degraded`). then -- for
`OVERLAY` images -- it patches the stock initramfs offline:
`unmkinitramfs` extracts the concatenated cpio, the `/scripts/overlay` premount is
added, and it is repacked as one uncompressed cpio. the kernel auto-loads that
initramfs on real hardware, so the first boot comes up overlay directly -- no
on-device initramfs build and no reboot. the cmdline gets `boot=overlay
overlay-upper=<shape>` (and the stock ` resize` token is stripped). the result is
a sparse raw image that flashes directly with no manual steps.

  on the first boot `overlay-firstboot.service` grows persist online to fill the
  card and (tmpfs shape only) seeds the persisted identity. persist is the last
  partition and the live overlay upper, so it is both mounted and busy: parted
  and BLKRRPART cannot re-read a busy disk's table, so `grow-persist` rewrites the
  trailing partition with `sfdisk --no-reread`, applies the new size in-kernel with
  `partx -u` (a BLKPG resize works on an in-use partition), then grows the fs online
  with `resize2fs` via its mountpoint -- the initramfs bind-mounts persist into the
  booted root so resize2fs can reach it. no data is moved and no reboot is needed.
  the stock `systemd-growfs-root.service` is masked for overlay images (it cannot
  grow an overlay root); a plain (non-`OVERLAY`) image keeps the stock raspios
  resize, which grows root instead.

  the service ships inert in `overlay/` (no wants symlink) and is enabled only for
  `OVERLAY` images. it orders only after `regenerate_ssh_host_keys.service` so the
  tmpfs seed captures real host keys, and deliberately depends on nothing in the
  network path, which would otherwise queue it behind the network-online timeout.

a dedicated third partition (ext4, label `persist`) is carved from a shrunk
rootfs and holds everything that must survive a reboot. two upper-layer shapes
are supported, selected at provision time:

- **ephemeral** (default): upper is tmpfs (reboot = clean slate, power-safe --
  the disk is read-only in normal operation). identity (ssh host keys,
  `machine-id`, NetworkManager connections, `/home`) is bind-mounted from the
  `persist` partition so it survives reboots automatically. other changes can be
  made durable on demand with `toolbox/overlay-commit`: it stages the live tmpfs
  upper onto `persist` (`rsync -aHAX`, keeping whiteouts and opaque-dir xattrs)
  and reboots; the initramfs folds the staged delta into a committed layer
  (`persist/data`). the fold moves entries by rename within `persist`, merging
  directories unless they are opaque, so xattrs survive and no file data is
  rewritten; the pending flag is cleared only after a `sync`, so a power cut
  mid-fold resumes on the next boot. that layer is the UPPER of an inner overlay
  over the base (`base + persist/data -> /committed`), with the tmpfs upper
  stacked above it (`/committed + tmpfs -> /`). because the committed layer is an
  overlay upper, whiteouts apply, so additions, modifications AND deletions all
  persist. the disk is only written during a commit, and `persist` (the big
  card-filling partition) is the commit target so size is not a constraint.
  volatile paths (the swapfile, `/var/log`, `/var/cache`, `/var/tmp`, `/tmp`) are
  excluded from a commit so it captures meaningful state, not churn.
- **persistent**: upper is the `persist` partition itself, so all changes
  survive immediately (reboot is no longer a reset, writes accumulate on `persist`).

the read-only-boot fstab option (`defaults,ro` on the firmware partition) is
mutually exclusive with `boot=overlay` in `raspi-config` and is applied only
when overlay root is not in use.

### kernel and firmware updates under an overlay root

the raspi-firmware kernel hooks copy each new kernel, initramfs and dtb onto the
FAT partition, which sits outside the overlay. left live, an apt upgrade would
switch the boot kernel at once while its modules stay in the volatile upper (an
uncommitted reboot, or a factory reset, then boots a kernel with no modules). so
an overlay image makes the FAT a derived artifact of the root:

- the build copies the finished FAT contents into the root's `/boot/firmware`
  (the base) and remounts the FAT at `/boot/bootfs` via fstab. the premount
  bind-mounts the root's `/boot/firmware` onto itself, because the hooks refuse
  to write anywhere that is not a mountpoint.
- kernel and firmware writes land in the writable layer like any other change:
  volatile until `overlay-commit` on tmpfs, durable at once on persist.
- on every boot the premount compares each `boot/firmware` path the durable
  writable layer touched against FAT, copies what differs, deletes what it
  whites out (`firmware_sync`). when a file the firmware loads changed (kernels,
  initramfs, dtbs/overlays, `config.txt`, `cmdline.txt`, firmware blobs) it
  reboots: the running kernel is still the old one, so the reboot is what
  switches kernels. other files just sync, e.g. the first-boot deletion of the
  `ssh.txt` trigger. a no-op sync costs one `cmp` per changed file.
- a factory reset first writes the base's version of every path the discarded
  layer touched back to FAT, then reboots into the base kernel.

files edited directly on the card's FAT from another machine stay as they are
unless the device has its own changed copy of the same path, which wins.

## factory reset (implemented)

at provision time a pristine snapshot of the persisted state is baked onto the
`persist` partition (`/persist/factory/`). a soft reset is a reboot (the tmpfs
upper is discarded, ephemeral shape only); a hard reset wipes the live
persisted state, restores the factory snapshot, regenerates ssh host keys and
`machine-id`, and reboots. triggers:

- a flag file `factory-reset` on the FAT firmware partition (`/boot/bootfs` on
  an overlay image), settable from any machine even when the device is unreachable
- a GPIO button held at boot (opt-in; not enabled by default, and requires a
  sustained hold so a floating pin cannot trigger a reset loop)
- `raspi-provision factory-reset` over ssh

## virtual test environment

the goal is a scripted environment as close to real RPi4 hardware as feasible.
it lives entirely under `tests/` and is driven by `make test`.

### why QEMU raspi4b

QEMU (>= 9.0) models a `raspi4b` machine that boots the genuine Raspberry Pi OS
arm64 image with the real kernel, dtb, and rootfs. this gives high fidelity for
the boot flow, the provisioning overlay, and SSH bring-up. we run it on arm64
under TCG (no KVM on an x86 host) to match the target architecture.

### fidelity tradeoffs

QEMU does not model all of the RPi4 SoC. the consequences:

| feature           | real RPi4         | QEMU raspi4b        | tested here |
|-------------------|-------------------|---------------------|-------------|
| boot + rootfs     | real              | real image          | yes         |
| USB host mode     | dwc2 host         | dwc2 host (modeled) | yes         |
| USB gadget (usb0) | dwc2 device       | gadget regs stubbed | no (deferred) |
| wifi (wlan0)      | brcmfmac          | not emulated        | no (deferred) |
| on-SoC ethernet   | GENET             | not emulated        | no          |

the harness drives the guest over the serial console, not SSH, so it needs no
guest networking: single-boot scenarios assert against a report block an in-guest
service prints to the console, and multi-boot scenarios (factory-reset) drive it
interactively with `tests/lib/serial.py`.

USB host mode needs a dtb patch: because qemu bypasses the firmware, the image's
`dtoverlay=dwc2` never applies, and the stock dtb leaves `/soc/usb@7e980000`
disabled with the legacy `brcm,bcm2708-usb` binding no mainline driver claims.
`patch_dtb_for_qemu` (in `tests/lib/qemu.sh`) rewrites the extracted dtb with
`fdtput` (compatible `snps,dwc2`, `dr_mode host`, `status okay`) so the kernel's
dwc2 host driver binds and attached usb devices enumerate.

### deferred features and their known approach

- **gadget mode**: QEMU's dwc2 gadget registers are stubbed, so `g_ether`/`usb0`
  cannot come up. the known path is to build the out-of-tree `dummy_hcd` module
  (absent from the raspios kernel) and package it via DKMS, then bring up `usb0`
  on the real kernel inside the guest.
- **wifi hotspot**: QEMU emulates no wifi. the known path is `mac80211_hwsim`,
  which creates virtual radios supporting AP/station mode -- but it is not in the
  raspios kernel, so it requires a generic-kernel lane.

both are recorded in ROADMAP.

### harness structure

the harness is fully root-free -- it builds the real image through the
`raspi-provision` binary and boots the artifact; no loop-mount, no sudo.

- the serial console: under qemu raspi4b the kernel console lands on the aux
  mini-uart (`ttyS0`, qemu's second `-serial`) because bluetooth owns the PL011
  (`ttyAMA0`). the harness sets `console=ttyS0,115200` and captures `serial_hd(1)`.
- `tests/lib/image-boot.sh` -- prepare a built image (`raspi-provision image`) for qemu:
  with `guestfish` it injects the report service into a work copy of the image and
  extracts kernel/dtb/cmdline (+ the offline-patched initramfs for overlay images;
  a plain image boots its ext4 root directly)
- `tests/lib/qemu.sh`    -- launch raspi4b with the extracted kernel/dtb/image (and
  optional USB devices). `patch_dtb_for_qemu` enables dwc2 host mode and disables
  the watchdog node; `QEMU_SERIAL_SOCK`/`QEMU_QMP` + `qmp_quit` enable multi-boot tests
- `tests/lib/serial.py`  -- drive the serial console for multi-boot scenarios: wait
  for login, log in, prime sudo, run a piped script (used by factory-reset)
- `tests/lib/wait.sh`    -- poll the console log for the report-end marker
- `tests/image-e2e/`     -- the in-guest report service injected at test time
- `tests/scenarios/`     -- the checks: `image-e2e.sh` (`make test-e2e
  MODE=plain|persist|tmpfs`: build + boot, assert provisioning -- writable ext4
  root for plain, or overlay root + baked user + online persist grow for overlay),
  `usb-host.sh` (usb mass-storage enumeration), `factory-reset.sh` (multi-boot: the
  reset reverts the overlay upper to the read-only base)

work artifacts (the work copy of the card, extracted kernel/dtb/initramfs, console
logs) live in `tests/.work/` and are gitignored (`make test-clean` removes them).
each test builds a fresh image and boots it; the first boot is slow under TCG (the
image expands and provisions), so a run is a few minutes per mode.
