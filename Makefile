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

# build a project whose overlay outgrows the stock root, assert it landed whole.
test-large-overlay: build
	tests/scenarios/large-overlay.sh
.PHONY: test-large-overlay

# multi-boot: a directory the project lists in /etc/persist.d survives a power cut.
test-persist-paths: build
	tests/scenarios/persist-paths.sh
.PHONY: test-persist-paths

# device-free: fake ssh/rsync record the maintain `update` command sequence.
test-update: build
	python3 tests/scenarios/maintain-update.py
.PHONY: test-update

# device-free: a fake sudo lets dd write gzip and raw images to a file standing in for the card.
test-flash: build
	python3 tests/scenarios/flash-image.py
.PHONY: test-flash

# standard pre-commit suite: maintain update + flash + overlay provisioning (persist) + usb host mode.
test: test-update test-flash test-e2e test-usb-host
.PHONY: test

test-clean:
	rm -rf tests/.work
.PHONY: test-clean

precommit: test
.PHONY: precommit
