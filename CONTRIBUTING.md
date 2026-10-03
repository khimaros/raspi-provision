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
- `toolbox/` -- the offline build engine (`build-image`) and on-device helpers
  (`grow-persist`, `seed-persist`, `overlay-commit`)
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
- `make test-update`        -- device-free: fake `ssh`/`rsync` record the `update`
  command sequence and assert apt lists refresh before the depends install
- `make test`               -- the standard pre-commit suite: `test-update` +
  `test-e2e` (persist) + `test-usb-host`
- `make test-clean`         -- remove work artifacts in `tests/.work/`

before committing, run `make precommit` (runs `make test`). prefer end-to-end
integration tests over unit tests.

### prerequisites

- a rust toolchain (pinned to 1.95 via `.mise.toml`; `mise install` provides it)
- `qemu-system-aarch64` >= 11 (provides the `raspi4b` machine)
- `libguestfs-tools` (`image` and the tests build/inspect images via guestfish)
- `dtc` (device-tree-compiler); `mtools` + `dosfstools` (for the usb-host test);
  `rsync`, `xz-utils`, `curl`
- `sudo` only for `flash` (writing the card). the build and all tests need no root.

the first boot of each test is slow: arm64 runs under TCG (no KVM on x86 hosts) and
the image expands/provisions on first boot.
