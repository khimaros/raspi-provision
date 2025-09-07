IMAGE_RASPIOS_SOURCE := https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz
IMAGE_RASPIOS := ./images/2025-05-13-raspios-bookworm-arm64-lite.img.xz

MOUNT_DEVICE := /dev/sda
MOUNT_ROOTFS := /media/$(USER)/rootfs
MOUNT_BOOTFS := /media/$(USER)/bootfs

CUSTOM_HOSTNAME := empusa
CUSTOM_USERNAME := empusa
# NOTE: password must be at least 8 bytes for hotspot to work
CUSTOM_PASSWORD := empusa05

ADDRESS := 10.55.0.1
#ADDRESS := 10.55.1.1
#ADDRESS := 10.55.2.1
#ADDRESS := $(CUSTOM_HOSTNAME).local

null:
	@echo "see readme for instructions"
.PHONY: null

###############
## PROVISION ##
###############

customize:
	sed -i 's/^127.0.1.1\t.*/127.0.1.1	$(CUSTOM_HOSTNAME)/g' rootfs/etc/hosts
	sed -i 's/^ssid=.*/ssid=$(CUSTOM_HOSTNAME)/g' rootfs/etc/NetworkManager/system-connections/shared-hotspot.nmconnection
	sed -i 's/^psk=.*/psk=$(CUSTOM_PASSWORD)/g' rootfs/etc/NetworkManager/system-connections/shared-hotspot.nmconnection
	mv rootfs/home/* rootfs/home/user.tmp
	mv rootfs/home/user.tmp rootfs/home/$(CUSTOM_USERNAME)
.PHONY: customize

authorize:
	cat $(HOME)/.ssh/id_rsa.pub > rootfs/root/.ssh/authorized_keys
	cat $(HOME)/.ssh/id_rsa.pub > rootfs/home/$(CUSTOM_USERNAME)/.ssh/authorized_keys
.PHONY: authorize

download:
	curl -o $(IMAGE_RASPIOS) $(IMAGE_RASPIOS_SOURCE)
.PHONY: download

flash:
	xzcat $(IMAGE_RASPIOS) | sudo dd of=$(MOUNT_DEVICE) status=progress
	sudo sync $(MOUNT_DEVICE)
.PHONY: flash

mount:
	sudo mkdir -p $(MOUNT_ROOTFS) $(MOUNT_BOOTFS)
	sudo mount $(MOUNT_DEVICE)1 $(MOUNT_BOOTFS)
	sudo mount $(MOUNT_DEVICE)2 $(MOUNT_ROOTFS)
.PHONY: mount

eject:
	sudo umount $(MOUNT_BOOTFS)
	sudo umount $(MOUNT_ROOTFS)
	sudo eject $(MOUNT_DEVICE)
	sudo rmdir $(MOUNT_BOOTFS) $(MOUNT_ROOTFS)
.PHONY: eject

create:
	echo $(CUSTOM_HOSTNAME) > rootfs/etc/hostname
	./toolbox/create-userconf $(CUSTOM_USERNAME) $(CUSTOM_PASSWORD) > bootfs/userconf.txt
	sudo rsync --exclude-from=.gitignore -rlptDv rootfs/ $(MOUNT_ROOTFS)/
	sudo rsync --exclude-from=.gitignore -rlptDv bootfs/ $(MOUNT_BOOTFS)/
	sudo ./toolbox/append-cmdline $(MOUNT_BOOTFS)/cmdline.txt "cfg80211.ieee80211_regdom=US"
	sudo ./toolbox/append-cmdline $(MOUNT_BOOTFS)/cmdline.txt "modules-load=dwc2,g_ether"
	sudo ./toolbox/append-cmdline $(MOUNT_BOOTFS)/cmdline.txt "g_ether.dev_addr=12:22:33:44:55:66 g_ether.host_addr=16:22:33:44:55:66"
.PHONY: create

finalize:
	ssh root@$(ADDRESS) chown -R $(CUSTOM_USERNAME):$(CUSTOM_USERNAME) /home/$(CUSTOM_USERNAME)/
	ssh root@$(ADDRESS) nmcli radio wifi on
	sleep 2
	ssh root@$(ADDRESS) nmcli connection up shared-hotspot
.PHONY: finalize

push:
	rsync --exclude-from=.gitignore -rlptDv rootfs/ root@$(ADDRESS):/
	rsync --exclude-from=.gitignore -rlptDv bootfs/ root@$(ADDRESS):/boot/
	cat default-packages | xargs ssh root@$(ADDRESS) apt -y install
.PHONY: push

update: push
	ssh root@$(ADDRESS) apt update
	ssh root@$(ADDRESS) apt full-upgrade --autoremove --purge
.PHONY: update

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

reboot:
	ssh root@$(ADDRESS) reboot
.PHONY: reboot

poweroff:
	ssh root@$(ADDRESS) poweroff
.PHONY: poweroff
