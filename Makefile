# raspi-provision is a rust binary (src/, built with cargo); this makefile builds
# and tests it. end users run `raspi-provision <cmd>`, not make -- see README.md.

CARGO := cargo
BIN := target/release/raspi-provision

build:
	$(CARGO) build
.PHONY: build

build-release:
	$(CARGO) build --release
.PHONY: build-release

# install the optimized binary onto PATH for local use.
install: build-release
	install -Dm755 $(BIN) $(HOME)/.local/bin/raspi-provision
.PHONY: install

null:
	@echo "see README for instructions; end users run 'raspi-provision <cmd>'"
.PHONY: null

##########
## TEST ##
##########

# the virtual test environment builds the real image THROUGH the binary and boots
# the artifact on qemu raspi4b, fully root-free (no loop-mount, no sudo). the
# scenarios read CUSTOM_* from the environment, so e.g. `CUSTOM_HOSTNAME=foo make
# test-e2e` works. see tests/README.md.

# root-free end-to-end test: build an image and boot it, asserting provisioning.
# MODE selects the shape -- plain, persist (default), or tmpfs.
MODE := persist
test-e2e: build
	tests/scenarios/image-e2e.sh $(MODE)
.PHONY: test-e2e

test-usb-host: build
	tests/scenarios/usb-host.sh
.PHONY: test-usb-host

# multi-boot: write a change, set the reset flag, reboot, assert it reverted.
test-factory-reset: build
	tests/scenarios/factory-reset.sh
.PHONY: test-factory-reset

# multi-boot: commit replaced/deleted/new files on tmpfs, assert the fold kept them.
test-overlay-commit: build
	tests/scenarios/overlay-commit.sh
.PHONY: test-overlay-commit

# multi-boot: install a newer kernel, commit, boot it from FAT, reset to the base.
test-kernel-update: build
	tests/scenarios/kernel-update.sh
.PHONY: test-kernel-update

# build a project whose depends/ adds a package, boot offline, assert it is installed.
test-bake-depends: build
	tests/scenarios/bake-depends.sh
.PHONY: test-bake-depends

# device-free: fake ssh/rsync record the maintain `update` command sequence.
test-update: build
	python3 tests/scenarios/maintain-update.py
.PHONY: test-update

# standard pre-commit suite: maintain update + overlay provisioning (persist) + usb host mode.
test: test-update test-e2e test-usb-host
.PHONY: test

test-clean:
	rm -rf tests/.work
.PHONY: test-clean

precommit: test
.PHONY: precommit
