# RASPI PROVISION

provision RPi for SSH access over RNDIS (USB), ethernet, and WiFi access point

access via RNDIS, ethernet, and the shared WiFi hotspot is available on first
boot -- everything is baked into the image

default hostname `empusa`, username `empusa`, password `empusa05`

default hotspot ssid is same as hostname, psk same as password

`raspi-provision` is a single binary: it carries a base image overlay and builds
flashable, provisioned images offline. use it as-is, or layer your own files and
packages on top of the base from a separate project directory (see
[reuse](#reuse-in-your-own-project)).

## install

```
make install      # builds with cargo, installs to ~/.local/bin/raspi-provision
```

or `cargo install --path .`. it shells out to `libguestfs-tools`, `xz-utils`, and
`curl`, plus `apt-get`, `qemu-system-aarch64` (>= 11) and `dtc` to install
`depends/` at build time (see [CONTRIBUTING.md](CONTRIBUTING.md) for the full
prerequisite list).

## configure

create a `customize.env` (gitignored) to override the defaults; the binary reads
it from the current directory, or from DIR with `-C DIR` (e.g. `raspi-provision
-C ~/my-appliance image`). all keys are optional:

```
CUSTOM_HOSTNAME=myhost
CUSTOM_USERNAME=myuser
CUSTOM_PASSWORD=mypassword   # at least 8 bytes so the hotspot works
OVERLAY=tmpfs                # persist | tmpfs; unset builds a plain image
MOUNT_DEVICE=/dev/sdb        # the sdcard device that `flash` writes
ADDRESS=10.55.0.1            # a running device, for the maintain commands
CMDLINE_EXTRA=psi=1          # kernel parameters to add, space separated, unquoted
```

WARNING: if `MOUNT_DEVICE` is wrong you risk destroying important data on that
device. it defaults to `/dev/sda`.

(optional) choose a different upstream image via `IMAGE_RASPIOS_SOURCE`.

## provision

the image is built fully offline and flashed ready to run -- no on-device setup.

```
raspi-provision download         # fetch the upstream raspios image (once)
raspi-provision authorize        # (optional) bake in your ssh public key
raspi-provision image            # build a provisioned image
raspi-provision flash            # write it to the sdcard (MOUNT_DEVICE)
```

`image` writes `images/<hostname>.img.gz`, and `flash` decompresses it on the way
to the card. both take a path instead, relative to the project, to keep several
images side by side: `raspi-provision image images/kiosk.img.gz`, then
`raspi-provision flash images/kiosk.img.gz`. a path that does not end in `.gz` is
a raw image.

a card that was flashed before KEEPS ITS PERSIST PARTITION, with `flash` and
with `ota` (below): `/home`, the ssh host keys and machine id, saved network
connections and whatever a project lists in `/etc/persist.d` are as they were
under the new image. what does not carry over is any change made to the old
system itself, committed or not, since it was recorded against the old root:
the new image drops those on its first boot. `--wipe` on either command
replaces the partition too, for a card that starts over.

keeping needs the card's persist partition to be exactly where the new image
has its own, and says so when it is not and the whole card is written instead.
the root before it is sized to its contents, so persist starts on the next
multiple of `PERSIST_ALIGN_MIB` (1024) after it: rebuilds of one project land
on the same place, and an image that grew past a boundary, or a different
project's, does not. an image built before this existed is never kept under,
as it would not know to drop the old system's changes.

set `OVERLAY=persist` (or `tmpfs`) in `customize.env` for the read-only overlay
root (see [resilience](#resilience)).

insert the card into the RPi and connect it via USB-C for power and connectivity.

NOTE: the first boot takes a few minutes while the card grows to fill the sdcard.
an OVERLAY image boots straight into the overlay root -- no on-device enablement
and no reboot.

the device boots fully provisioned -- ssh in with `raspi-provision ssh` (or
`raspi-provision ssh --root`). continue with [maintain](#maintain).

## maintain

```
raspi-provision nmtui            # choose an internet connection
raspi-provision update           # push overlay + packages to a running device
raspi-provision network hotspot  # bring up the shared WiFi hotspot
raspi-provision ssh              # shell in
raspi-provision ota              # DESTRUCTIVE: write a built image to its card, and restart
```

`ota` is `flash` for a device that is up: it sends the image over ssh, the
device writes it to the card it booted from and restarts into it, and the card
never leaves the device. it takes the same optional path as `flash`, and keeps
the persist partition or, with `--wipe`, replaces it, as `flash` does. the
device goes on running from memory while its card is written. a transfer that fails leaves the
card half written and the device still up, to be sent the image again; one that
loses power in that state needs its card in a reader, as does one whose new
image does not start.

`ota` first waits for the device to answer ssh at `ADDRESS`, for up to
`OTA_WAIT_SECONDS` (60 unless set in `customize.env` or the environment), and
sends nothing to one that does not. so it can follow at once on whatever brings
the device's network up, such as a project telling its own service to give the
usb port back to the shared rndis connection.

a device whose persist partition was replaced makes new ssh host keys on its
first boot. after such a `flash` or `ota`, and only then, the keys saved for it
in your `known_hosts` are forgotten, under its `ADDRESS`, its hostname (and `.local`) and the three shared addresses,
and every command here that uses ssh takes the key of a host it has none for
(`StrictHostKeyChecking=accept-new`). a key that changes at any other time is
still refused. `ssh-keygen` leaves the file as it was in `known_hosts.old`.

NOTE: connecting to a WiFi network deactivates the shared WiFi hotspot and (if
autoconnect is enabled) may keep it from starting on boot.

NOTE: on a `tmpfs` overlay image, pushed changes live in the volatile upper and
are lost on reboot; rebuild and reflash for a permanent change, or use
`raspi-provision overlay-commit`. on `persist` (or a plain image) they stick.

the packages listed under `depends/` (one per line, `#` comments; organize by
category across files, e.g. `depends/base`, `depends/vpn`) are installed into the
image by `image`, so a fresh card runs without internet, and kept current by
`update`. the build downloads them with the host's `apt-get` (cached under
`images/.apt-cache`) and installs them in a one-off qemu boot; set
`BAKE_DEPENDS=0` to skip that and leave them to `update`.

## shared networks

each shared connection has its own address/subnet:

- shared-rndis:    10.55.0.1/24
- shared-ethernet: 10.55.1.1/24
- shared-hotspot:  10.55.2.1/24

choose one for the maintain commands with `ADDRESS` in `customize.env` (or inline,
e.g. `ADDRESS=10.55.1.1 raspi-provision ssh`).

to activate the shared WiFi hotspot, run `raspi-provision network hotspot` -- NOTE:
this disconnects from any other configured WiFi network (default ssid/psk is the
hostname/password).

## resilience

to survive power outages, the root partition can be mounted read-only behind an
overlayfs (writes go to a volatile or persistent upper layer), so an unclean
shutdown cannot corrupt it. write reduction (volatile journald, `noatime`, no
swap, masked apt/man-db timers) is applied by default.

build an overlay image by setting `OVERLAY` in `customize.env`:

- `OVERLAY=persist`: all changes survive reboots; persist grows to fill the card
- `OVERLAY=tmpfs`: every reboot is a clean slate; ssh host keys, machine-id,
  NetworkManager connections, and `/home` persist via the `persist` partition.
  to persist more directories, list them one per line in a file under
  `/etc/persist.d/` in your project's overlay (for example `/var/lib/myapp`).
  make other changes durable on demand with `raspi-provision overlay-commit` -- it
  commits the current state to `persist` and reboots into it; uncommitted changes
  are discarded on reboot

`raspi-provision image` builds the image fully offline and unprivileged
(libguestfs, no sudo): it carves the `persist` partition, bakes your user, and for
an overlay image patches the stock initramfs so the card boots the overlay root
directly. on the first boot the device grows persist online to fill the card -- no
enablement step and no reboot. the built image is small regardless of card size:
gzip-compressed by default, sparse when raw. tune the minimum persist size with
`PERSIST_SIZE_MIB`.

on an overlay image the FAT boot partition is mounted at `/boot/bootfs`;
`/boot/firmware` is the root's own copy. kernel and firmware upgrades (e.g. from
`raspi-provision update`) land there like any other change and reach the boot
partition only once durable: after `overlay-commit` on `tmpfs`, right away on
`persist`. the next boot copies them over and reboots once more into the new
kernel. a factory reset puts the image's original kernel back.

to factory reset (restore provisioned state and regenerate identity):

- run `raspi-provision factory-reset` over ssh, or
- create a file named `factory-reset` on the FAT boot partition from any machine, or
- hold a reset button (GPIO `21` to ground by default) while powering on -- the
  button trigger is opt-in hardware: enable it with `systemctl enable
  factory-reset-button` (override pin via `RESET_GPIO_LINE`)

the reset runs from the initramfs on the next boot and reboots into a clean state.

## reuse in your own project

`raspi-provision` carries the base overlay inside the binary, so another project
only needs its own deltas:

```
raspi-provision init my-appliance   # scaffold customize.env, overlay/, depends/
cd my-appliance
$EDITOR customize.env               # hostname, OVERLAY, etc.
```

drop files under `overlay/` using runtime paths -- `overlay/etc/my-service.conf`
lands on the ext4 root, `overlay/boot/firmware/config.txt` on the FAT firmware
partition. the root grows to fit, so large files are fine. list extra packages
under `depends/` (one per line, `#` comments), e.g. `depends/myapp`; an apt
source they need goes in `overlay/etc/apt/sources.list.d/`. then:

```
raspi-provision image && raspi-provision flash
```

your `overlay/` and `depends/` layer on top of the framework's base
(last-writer-wins per file), so you override or extend it without forking.
