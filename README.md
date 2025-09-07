# RASPI PROVISION

provision RPi for SSH access over RNDIS (USB), ethernet, and WiFi access point

access via RNDIS and ethernet will be available on first boot

shared WiFi hotspot will become available after provisioning is finalized

default hostname `empusa`, username `empusa`, password `empusa05`

default hotspot ssid is same as hostname, psk same as password

## configure

WARNING: if your sdcard is not `/dev/sda`, you should modify `MOUNT_DEVICE` in Makefile or you risk destroying important data

(optional) choose an image from [Raspberry Pi OS](https://www.raspberrypi.com/software/operating-systems/) and modify `IMAGE_RASPIOS` and `IMAGE_RASPIOS_SOURCE` in the Makefile

(optional) modify `CUSTOM_HOSTNAME`, `CUSTOM_USERNAME`, and `CUSTOM_PASSWORD` in Makefile and run `make customize` to modify your working tree.

## provision

run `make download` to download the upstream sdcard image

run `make flash` to write the image to the sdcard (default device `/dev/sda`)

eject, remove, reinsert, and remount the sdcard

NOTE: your desktop may handle the mount/eject flow for you, but if it doesn't, you can use `make eject` and `make mount`

run `make create` to overlay default configs onto the mounted sdcard (default path is `/media/$(USER)/{rootfs,bootfs}`)

eject the sdcard again and insert into the RPi

connect the RPi via USB-C to your laptop for power and connectivity

NOTE: wait a while (minutes) on first boot for sdcard rootfs expansion

you can now connect to the ssh server with `make ssh` or `make ssh-root`

run `make finalize` to fix permissions, activate shared-hotspot, and install default packages

## maintain

run `make nmtui` to choose an internet connection (select "Activate a connection")

NOTE: connecting to a WiFi network will deactivate the shared WiFi hotspot and (if autoconnect is enabled for that network) may prevent it from starting up on boot

run `make update` to push file and package updates (rinse and repeat as needed)

## shared networks

each shared connection has its own address/subnet:

- shared-rndis:    10.55.0.1/24
- shared-ethernet: 10.55.1.1/24
- shared-hotspot:  10.55.2.1/24

you can choose one of these with eg. `make ADDRESS=10.55.1.1 ssh`

to activate the shared WiFi hotspot, run `make network-hotspot` -- NOTE: this will disconnect from any other configured WiFi network (default ssid/psk is same as hostname/password)
