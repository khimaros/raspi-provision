# CONTRIBUTING

`raspi-provision` is a rust binary that embeds the framework tree (`overlay/`,
`depends/`, `toolbox/`, `tests/`) and execs the bash/guestfish build engine in
`toolbox/build-image`. end users run the binary; this file is for working on the
framework itself.

## layout

- `src/` + `build.rs` + `Cargo.toml` -- the cli. `build.rs` tars the framework
  assets into the binary at compile time (preserving exec bits)
- `overlay/` -- the base image overlay, in runtime paths. files under
  `boot/firmware/` go to the FAT firmware partition, everything else to the ext4
  root. a downstream project layers its own `overlay/` on top (last-writer-wins)
- `depends/` -- base package lists installed by `update` (one per line, # comments)
- `toolbox/` -- the offline build engine (`build-image`, `bake-depends`) and on-device helpers
  (`grow-persist`, `seed-persist`, `overlay-commit`, `ota-write`), and
  `write-image`, which puts an image on a card for `flash` and for `ota`
- `tests/` -- the root-free qemu harness (see [tests/README.md](tests/README.md))

## build

```
make build        # cargo build --release -> target/release/raspi-provision
make install      # also install it to ~/.local/bin
```

then drive it from a working directory holding a `customize.env` (or point it at
one with `-C DIR`). for framework
development run it in place with `cargo run -- <cmd>` or
`target/release/raspi-provision <cmd>`.

## test

the virtual test environment builds the real image THROUGH the binary and boots
the artifact under qemu raspi4b, fully root-free (no loop-mount, no sudo). the
scenarios read `CUSTOM_*` from the environment.

- `make test-e2e`           -- build an image and boot it, asserting it provisions
  correctly. set `MODE` to the shape: `plain`, `persist` (default) or `tmpfs`
- `make test-usb-host`      -- attach an emulated USB device and assert the guest
  reads its sentinel (dwc2 host mode)
- `make test-factory-reset` -- write a change, set the reset flag, reboot, assert
  the initramfs reverted it (persist overlay, multi-boot)
- `make test-overlay-commit` -- tmpfs: commit a replaced dir, a deletion and a
  new file, power-cycle, assert the initramfs fold kept them
- `make test-kernel-update` -- tmpfs: install a newer kernel deb, commit, assert
  FAT follows only after the commit, the new kernel boots, a reset restores the base
- `make test-bake-depends`  -- build a throwaway project (via `-C`) whose
  `depends/` adds a package, and another from an apt source its overlay adds, boot
  offline, assert they and the base packages are in.
  the other scenarios build with `BAKE_DEPENDS=0` to stay fast
- `make test-large-overlay` -- build a project whose overlay outgrows the stock
  root and assert, with guestfish and no boot, that it landed whole. the one
  scenario that builds the default gzip image; the others name a raw one
- `make test-persist-paths` -- tmpfs: build a project whose overlay lists a
  directory in `/etc/persist.d`, cut the power, assert it alone kept its file
- `make test-update`        -- device-free: fake `ssh`/`rsync` record the `update`
  command sequence and assert apt lists refresh before the depends install
- `make test-flash`         -- device-free: a fake `sudo` runs the writer against a file
  standing in for the card, and assert it holds the image, gzip or raw, named or
  not, with its persist partition kept when it has one in the right place
- `make test-ota`           -- device-free: a fake `ssh` keeps what `ota` sends, and
  assert the device is handed the writers, then the image as gzip, to keep or wipe
- `make test-ota-write`     -- tmpfs: hand the writers a second image on a booted
  system, power-cycle, assert the card boots that image with home and the host
  key kept and the old system's changes gone. `OTA=wipe` for the other way.
  about 45 minutes, so not in `make test`
- `make test`               -- the standard pre-commit suite: `test-update` +
  `test-flash` + `test-ota` + `test-e2e` (persist) + `test-usb-host`
- `make test-clean`         -- remove work artifacts in `tests/.work/`
- `make clean`              -- that, and cargo's `target/`. `images/` is left

before committing, run `make precommit` (runs `make test`). prefer end-to-end
integration tests over unit tests.

### prerequisites

- a rust toolchain (pinned to 1.95 via `.mise.toml`; `mise install` provides it)
- `qemu-system-aarch64` >= 11 (provides the `raspi4b` machine; also used by
  `image` to install `depends/`)
- `apt-get` + `dpkg-deb` (host-side download of `depends/` for the image)
- `libguestfs-tools` (`image` and the tests build/inspect images via guestfish)
- `dtc` (device-tree-compiler); `mtools` + `dosfstools` (for the usb-host test);
  `rsync`, `xz-utils`, `curl`
- `sudo` only for `flash` (writing the card). the build and all tests need no root.

the first boot of each test is slow: arm64 runs under TCG (no KVM on x86 hosts) and
the image expands/provisions on first boot.
