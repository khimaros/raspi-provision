# CONTRIBUTING

## build

configure in `customize.env` (hostname/user/password, optionally `MOUNT_DEVICE` /
`OVERLAY`); the Makefile defaults apply when it is absent. then:

- `make download`  -- fetch the upstream raspios image (once)
- `make image`     -- build a flashable, provisioned image offline and
  unprivileged (libguestfs). set `OVERLAY=persist` or `OVERLAY=tmpfs` for the
  read-only overlay root. self-contained: hostname/user/password/hotspot are baked
  from `CUSTOM_*`, with no separate `make customize` step and no tree mutation
- `make authorize` -- (optional) bake your ssh pubkey before `make image`
- `make flash`     -- write the built image to the card (`MOUNT_DEVICE`)

## test

the virtual test environment builds the real image and boots the artifact under
QEMU raspi4b, fully root-free (no loop-mount, no sudo). see DESIGN.md for what it
does and does not cover.

- `make test-e2e`           -- build an image and boot it, asserting it provisions
  correctly. set `MODE` to the shape: `plain`, `persist` (default) or `tmpfs`
- `make test-usb-host`      -- attach an emulated USB device and assert the guest
  reads its sentinel (dwc2 host mode)
- `make test-factory-reset` -- write a change, set the reset flag, reboot, assert
  the initramfs reverted it (persist overlay, multi-boot)
- `make test`               -- the standard pre-commit suite: `test-e2e` (persist)
  + `test-usb-host`
- `make test-clean`         -- remove work artifacts in `tests/.work/`

before committing, run `make precommit` (runs `make test`). prefer end-to-end
integration tests over unit tests.

### prerequisites

- `qemu-system-aarch64` >= 11 (provides the `raspi4b` machine)
- `libguestfs-tools` (`make image` and the tests build/inspect images via guestfish)
- `dtc` (device-tree-compiler); `mtools` + `dosfstools` (for the usb-host test);
  `rsync`, `xz-utils`
- `sudo` only for `make flash` (writing the card). the build and all tests need no root.

the first boot of each test is slow: arm64 runs under TCG (no KVM on x86 hosts) and
the image expands/provisions on first boot.
