# RASPI PROVISION

provision RPi for SSH access over RNDIS (USB), ethernet, and WiFi access point

access via RNDIS, ethernet, and the shared WiFi hotspot is available on first
boot -- everything is baked into the image

default hostname `empusa`, username `empusa`, password `empusa05`

default hotspot ssid is same as hostname, psk same as password

## configure

create `customize.env` (gitignored) to override the defaults -- it is read by
every `make` target. all keys are optional:

```
CUSTOM_HOSTNAME=myhost
CUSTOM_USERNAME=myuser
CUSTOM_PASSWORD=mypassword   # at least 8 bytes so the hotspot works
OVERLAY=tmpfs                # persist | tmpfs; unset builds a plain image
MOUNT_DEVICE=/dev/sdb        # the sdcard device that `make flash` writes
```

WARNING: if `MOUNT_DEVICE` is wrong you risk destroying important data on that
device. it defaults to `/dev/sda`.

(optional) choose an image from [Raspberry Pi OS](https://www.raspberrypi.com/software/operating-systems/) and modify `IMAGE_RASPIOS` and `IMAGE_RASPIOS_SOURCE` in the Makefile

## provision

the image is built fully offline and flashed ready to run -- no on-device setup.

run `make download` to download the upstream raspios image

(optional) run `make authorize` to bake in your ssh public key

run `make image` to build a provisioned image -- it bakes your hostname, user,
and password from `customize.env` (or the defaults) with no working-tree changes.
add `OVERLAY=persist` (or `OVERLAY=tmpfs`) for the read-only overlay root (see
[#resilience](#resilience))

run `make flash` to write the image to the sdcard (default `/dev/sda` -- mind the
WARNING above)

insert the card into the RPi and connect it via USB-C for power and connectivity

NOTE: the first boot takes a few minutes while the card grows to fill the sdcard.
an OVERLAY image boots straight into the overlay root -- no on-device enablement
and no reboot

the device boots fully provisioned -- ssh in with `make ssh` or `make ssh-root`

continue with [#maintain](#maintain)

## maintain

run `make nmtui` to choose an internet connection (select "Activate a connection")

NOTE: connecting to a WiFi network will deactivate the shared WiFi hotspot and (if autoconnect is enabled for that network) may prevent it from starting up on boot

run `make update` to push file and package updates to a running device (rinse and
repeat as needed)

NOTE: on a `tmpfs` overlay image these changes live in the volatile upper and are
lost on reboot; rebuild and reflash for a permanent change. on a `persist` overlay
(or a plain image) they stick.

## shared networks

each shared connection has its own address/subnet:

- shared-rndis:    10.55.0.1/24
- shared-ethernet: 10.55.1.1/24
- shared-hotspot:  10.55.2.1/24

you can choose one of these with eg. `make ADDRESS=10.55.1.1 ssh`

to activate the shared WiFi hotspot, run `make network-hotspot` -- NOTE: this will disconnect from any other configured WiFi network (default ssid/psk is same as hostname/password)

## resilience

to survive power outages, the root partition can be mounted read-only behind an
overlayfs (writes go to a volatile or persistent upper layer), so an unclean
shutdown cannot corrupt it. write reduction (volatile journald, `noatime`, no
swap, masked apt/man-db timers) is applied by default.

build an overlay image by setting `OVERLAY` when you run `make image`:

- `OVERLAY=persist`: all changes survive reboots; persist grows to fill the card
- `OVERLAY=tmpfs`: every reboot is a clean slate; ssh host keys, machine-id,
  NetworkManager connections, and `/home` persist via the `persist` partition.
  make other changes durable on demand with `make overlay-commit` (or
  `overlay-commit` on the device) -- it commits the current state to `persist`
  and reboots into it; uncommitted changes are discarded on reboot

`make image` builds the image fully offline and unprivileged (libguestfs, no
sudo): it carves the `persist` partition, bakes your user, and for an overlay
image patches the stock initramfs so the card boots the overlay root directly. on
the first boot the device grows persist online to fill the card -- no enablement
step and no reboot. the built image is sparse (a few GB regardless of card size).
tune the minimum persist size with `PERSIST_SIZE_MIB`.

to factory reset (restore provisioned state and regenerate identity):

- run `make factory-reset` over ssh, or
- create a file named `factory-reset` on the FAT boot partition from any machine, or
- hold a reset button (GPIO `21` to ground by default) while powering on -- the
  button trigger is opt-in hardware: enable it with `systemctl enable
  factory-reset-button` (override pin via `RESET_GPIO_LINE`)

the reset runs from the initramfs on the next boot and reboots into a clean state.
