# local config overrides (hostname/user/password, optionally device/address/etc).
# optional: a fresh checkout without one falls back to the defaults below.
-include customize.env

IMAGE_RASPIOS_SOURCE := https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz

IMAGE_RASPIOS := ./images/raspios-lite.img.xz

MOUNT_DEVICE ?= /dev/sda

MOUNT_ROOTFS := /run/media/$(USER)/rootfs
MOUNT_BOOTFS := /run/media/$(USER)/bootfs
#MOUNT_ROOTFS := /run/media/$(USER)/RASPIROOT
#MOUNT_BOOTFS := /run/media/$(USER)/RASPIFIRM

# defaults; override any of these in customize.env (or on the command line)
CUSTOM_HOSTNAME ?= empusa
CUSTOM_USERNAME ?= empusa
# NOTE: password must be at least 8 bytes for hotspot to work
CUSTOM_PASSWORD ?= empusa05

# raspberry pi os assigns the first user (created from userconf.txt on first
# boot) uid/gid 1000; bake the home owner to match so the user owns its home.
FIRST_USER_UID := 1000

ADDRESS := 10.55.0.1
#ADDRESS := 10.55.1.1
#ADDRESS := 10.55.2.1
#ADDRESS := $(CUSTOM_HOSTNAME).local

# resilience: size of the persist partition. set OVERLAY to tmpfs or persist to
# bake the read-only overlay root into a built image (tmpfs = ephemeral root,
# persist = all changes survive); empty OVERLAY builds a plain image.
#   make OVERLAY=persist image
PERSIST_SIZE_MIB := 128
OVERLAY ?=
IMAGE_PROVISIONED := ./images/$(CUSTOM_HOSTNAME).img

null:
	@echo "see readme for instructions"
.PHONY: null

###############
## PROVISION ##
###############

# bake your ssh pubkey into the image (run before 'make image' if you want key
# auth). writes the rootfs/ template home (.ssh applied to /home/<user> at build)
# and root. hostname/user/password/hotspot are baked by 'make image' itself -- no
# separate customize step.
authorize:
	mkdir -p rootfs/root/.ssh rootfs/home/user/.ssh
	cat $(HOME)/.ssh/id_rsa.pub > rootfs/root/.ssh/authorized_keys
	cat $(HOME)/.ssh/id_rsa.pub > rootfs/home/user/.ssh/authorized_keys
.PHONY: authorize

download:
	curl -o $(IMAGE_RASPIOS) $(IMAGE_RASPIOS_SOURCE)
.PHONY: download

push:
	rsync --exclude-from=.gitignore -rlptDv rootfs/ root@$(ADDRESS):/
	#rsync --exclude-from=.gitignore -rlptDv bootfs/ root@$(ADDRESS):/boot/
	cat default-packages | xargs ssh root@$(ADDRESS) apt -y install
.PHONY: push

update: push
	ssh root@$(ADDRESS) apt update
	ssh root@$(ADDRESS) apt full-upgrade --autoremove --purge
.PHONY: update

################
## RESILIENCE ##
################

# build a flashable, provisioned image offline (sparse raw), fully self-contained:
# hostname/user/password/hotspot are baked from CUSTOM_* -- no 'make customize'
# step and no working-tree mutation. with OVERLAY set, bakes the overlay root so a
# flashed card self-enables it on first boot, with no manual partition/overlay steps.
#   make OVERLAY=persist image && make flash
image:
	CUSTOM_HOSTNAME=$(CUSTOM_HOSTNAME) CUSTOM_USERNAME=$(CUSTOM_USERNAME) CUSTOM_PASSWORD=$(CUSTOM_PASSWORD) \
		PERSIST_SIZE_MIB=$(PERSIST_SIZE_MIB) \
		./toolbox/build-image $(IMAGE_RASPIOS) $(IMAGE_PROVISIONED) $(OVERLAY)
.PHONY: image

# write a built image (from 'make image') to the card. oflag=direct sends each
# block straight to the media instead of the page cache: a cheap/flaky usb reader
# can silently drop cached (conv=fsync) writes, reporting success while the card
# gets nothing or corrupt data.
flash:
	-sudo umount $(MOUNT_DEVICE)?* 2>/dev/null
	sudo dd if=$(IMAGE_PROVISIONED) of=$(MOUNT_DEVICE) bs=4M oflag=direct status=progress
	sudo sync
.PHONY: flash

factory-reset:
	ssh root@$(ADDRESS) /usr/local/sbin/factory-reset
.PHONY: factory-reset

# commit the current volatile (tmpfs) overlay changes to persist (tmpfs images
# only). the device stages the changes and reboots to fold them in.
overlay-commit:
	ssh root@$(ADDRESS) /usr/local/sbin/overlay-commit
.PHONY: overlay-commit

#############
## NETWORK ##
#############

nmtui:
	ssh -tt root@$(ADDRESS) nmtui
.PHONY: nmtui

network-ethernet:
	ssh root@$(ADDRESS) nmcli connection up shared-ethernet
.PHONY: network-ethernet

network-hotspot:
	ssh root@$(ADDRESS) nmcli connection up shared-hotspot
.PHONY: network-hotspot

###########
## SHELL ##
###########

ssh:
	ssh $(CUSTOM_USERNAME)@$(ADDRESS)
.PHONY: ssh

ssh-root:
	ssh root@$(ADDRESS)
.PHONY: ssh

screen:
	ssh -t $(CUSTOM_USERNAME)@$(ADDRESS) -- screen -x -R -S control
.PHONY: screen

screen-root:
	ssh -t root@$(ADDRESS) -- screen -x -R -S control
.PHONY: screen-root

reboot:
	ssh root@$(ADDRESS) reboot
.PHONY: reboot

poweroff:
	ssh root@$(ADDRESS) poweroff
.PHONY: poweroff

##########
## TEST ##
##########

test-usb-host:
	CUSTOM_HOSTNAME=$(CUSTOM_HOSTNAME) CUSTOM_USERNAME=$(CUSTOM_USERNAME) CUSTOM_PASSWORD=$(CUSTOM_PASSWORD) \
		tests/scenarios/usb-host.sh
.PHONY: test-usb-host

# standard pre-commit suite: overlay provisioning (persist) + usb host mode.
# factory-reset is slow (two boots), so it is a separate target.
test: test-e2e test-usb-host
.PHONY: test

# root-free end-to-end test of an offline-built image: build it, boot the real
# artifact on qemu (no sudo), and assert it provisions correctly. set MODE to the
# image shape -- plain (writable root + stock grow), persist or tmpfs (overlay root).
#   make test-e2e MODE=plain
MODE := persist
test-e2e:
	CUSTOM_HOSTNAME=$(CUSTOM_HOSTNAME) CUSTOM_USERNAME=$(CUSTOM_USERNAME) CUSTOM_PASSWORD=$(CUSTOM_PASSWORD) \
		tests/scenarios/image-e2e.sh $(MODE)
.PHONY: test-e2e

# root-free factory-reset test (persist overlay, multi-boot on qemu): write a
# change, set the reset flag, reboot, assert the initramfs reverted it. needs no sudo.
test-factory-reset:
	CUSTOM_HOSTNAME=$(CUSTOM_HOSTNAME) CUSTOM_USERNAME=$(CUSTOM_USERNAME) CUSTOM_PASSWORD=$(CUSTOM_PASSWORD) \
		tests/scenarios/factory-reset.sh
.PHONY: test-factory-reset

test-clean:
	rm -rf tests/.work
.PHONY: test-clean

precommit: test
.PHONY: precommit
