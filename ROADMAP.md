# ROADMAP

```
[x] update wifi SSID and PSK during `customize`
[x] shared connection over RNDIS enabled by default
[x] shared connection over ethernet available
[x] shared connection over wlan available
[x] networking via NetworkManager only; mask the redundant systemd-networkd
    that raspios also ships (NM owns our interfaces, so networkd-wait-online
    just timed out and left the booted system reporting 'degraded')
[ ] re-evaluate systemd-networkd once it gains native wifi AP + interactive
    network selection: it now covers the wired shared connections (DHCPServer +
    IPMasquerade for usb0/ethernet) but does no wifi link management, so the
    hotspot and the 'choose a network' flow (raspi-provision nmtui) keep us on
    NetworkManager. its declarative model would suit the read-only overlay if
    wifi ever lands (or via NM + iwd as the wifi backend)
[x] virtualized test environment (qemu raspi4b boot + usb host mode; harness
    patches the extracted dtb to enable dwc2 host mode since qemu bypasses
    the firmware's dtoverlay handling)
[x] flash-and-go overlay image: 'make OVERLAY=persist image' (or 'tmpfs') builds
    a provisioned, sparse raw image that boots the overlay root directly on the
    first boot -- no on-device provisioning, no reboot. validated on the qemu
    harness for both shapes (overlay root, baked-user login, persist grown online
    to fill the card)
    [x] toolbox/build-image: root-free guestfish provision (no loop-mount, no
        sudo), carve persist offline, bake the user offline, patch the initramfs
    [x] patch the stock initramfs8/initramfs_2712 offline (unmkinitramfs extract,
        add /scripts/overlay, repack as one uncompressed cpio) so 'boot=overlay'
        comes up overlay directly -- it is auto-loaded on real hardware, no
        on-device rebuild and no reboot
    [x] bake the user offline (rename the stock uid-1000 template user) and
        finalize the stock first-boot user setup the way cancel-rename would:
        mask userconfig.service (else it hangs at a whiptail 'enter username'
        prompt on tty8, blocking multi-user.target) and drop the ssh
        rename_user.conf 'set up a valid user' banner. the user lives in the
        read-only lower, so factory reset preserves it
    [x] makefile 'image' / 'flash' targets gated by OVERLAY (no sudo)
    [x] first-boot grow persist to fill the card, online and reboot-free: the
        partition is the live overlay upper, so 'grow-persist' rewrites the
        trailing partition with sfdisk --no-reread, resizes it in-kernel with
        partx -u, then grows the fs online with resize2fs (overlay-firstboot
        .service). the persist partition is bind-mounted into the booted root so
        resize2fs can reach it. mask the stock systemd-growfs-root (it cannot
        grow an overlay root)
    [x] bake correct /home/<user> ownership (uid 1000) + drop the orphaned stock
        /home/pi in 'create', so a flashed card needs no 'make finalize' chown
    [x] prebake wifi radio enabled (NetworkManager.state) so finalize need not
        run 'nmcli radio wifi on'
    [x] enable iw-dev-wlan1 by default (wants symlink) + hotspot autoconnect, so
        finalize need not enable the AP
    [x] root-free e2e test ('make test-e2e MODE=plain|persist|tmpfs'): build the
        image, boot the real artifact on qemu via guestfish (no sudo), assert
        provisioning -- writable ext4 root for plain, or overlay root + baked
        user + online persist grow for overlay. (the old sudo loop-mount 'make
        test' still exists)
    [x] 'make flash' writes with oflag=direct so a flaky usb reader cannot
        silently drop cached writes (reporting success while the card gets
        nothing or corrupt data)
[~] overlay-commit: on a tmpfs overlay image, run from RAM (volatile, power-safe)
    but commit the current changes to persist on demand. the committed changes
    live on persist (the big card-filling partition) as an extra overlay lower,
    so disk is not a constraint (unlike a persist->base commit, which targets the
    small read-only root and is limited to tiny changes + adds no durability since
    persist already persists). 'overlay-commit' stages the live tmpfs upper to
    persist and reboots; the initramfs folds the staged delta into the committed
    layer before reassembling. identity (ssh keys etc.) keeps auto-persisting via
    the existing state binds.
    [x] v1: multi-lower (committed layer as an extra ro lower) -- adds/modifies
        persist, base-file deletions do not (documented). validated on qemu:
        write -> overlay-commit -> reboot survives; an uncommitted change is lost
    [x] v2: two stacked overlays (inner = base + persist committed upper, outer =
        that + tmpfs upper) so deletions persist too. validated on qemu: a deleted
        base file (/etc/motd) stays gone across reboot (the whiteout is folded into
        the committed layer and applied by the inner overlay)
    [x] commit excludes volatile paths (the swapfile /var/swap, /var/log,
        /var/cache, /var/tmp, /tmp) so a commit captures meaningful state -- the
        first-boot upper was ~230MB, almost all the /var/swap swapfile
    [x] swap + zram disabled entirely (validated: no swapon, no /var/swap, no
        /dev/zram0). trixie layers it in three places, so three rootfs overrides:
        rpi-swap Mechanism=none, an empty zram-generator.conf (no [zram0]), and an
        empty modules-load.d/20-zram-generator.conf (stop the module force-load).
        frees ~150-230MB RAM/boot + stops flash writes. the old dphys-swapfile mask
        targeted the wrong mechanism and never actually disabled swap
    [ ] optional persist-mode 'commit to factory baseline' (small changes only)
[x] consolidate make targets / self-contained build
    [x] phase A: fold `make customize` into build-image -- hostname/hosts/hotspot/
        home/user are baked from CUSTOM_* at build time; rootfs/ reverts to neutral
        templates; `make image` needs no separate customize step and stops mutating
        the working tree. validated on qemu (hostname baked correctly)
    [x] phase B: port factory-reset + usb-host coverage into the root-free harness
        (test-factory-reset multi-boots via serial.py/qmp_quit; test-usb-host
        enumerates an emulated usb-storage device). both validated on qemu
    [x] phase C: retired the legacy sudo loop-mount flow (create, test-image,
        test-boot, test-resilience, test-build-image + lib/image.sh/overlay.sh);
        precommit -> test (test-e2e persist + test-usb-host); docs rewritten
[x] reusable framework: ship raspi-provision as a single invoke-from-anywhere
    binary (rust) so other projects build images by overlaying their own files on
    the bundled base, with no vendored makefiles
    [x] unified asset layout: merge rootfs/ + bootfs/ into one overlay/ tree using
        runtime paths (overlay/etc/..., overlay/boot/firmware/... -> FAT). build-image
        takes an ordered OVERLAY_LAYERS (default the framework's own), merges last-
        wins, mounts the FAT firmware partition at boot/firmware, and tars the whole
        tree in so each file lands on the right partition. validated: plain + a
        project overlay (new ext4 file + overridden FAT config.txt) land correctly
    [x] depends/: replace default-packages with per-category package-list files
        (depends/base, depends/vpn, ...), one package per line, # comments; the
        effective list is the union across base + project layers. fed to `update`
    [x] rust cli (clap): a thin launcher that embeds the framework tree as a build-
        time tarball (build.rs; tar preserves the exec bit include_dir drops),
        extracts it per run, reads customize.env (+ process-env override), sets
        OVERLAY_LAYERS to bundled-base + ./overlay, and execs the bash/guestfish
        engine -- no logic rewrite. ~130K embedded payload
    [x] subcommands: init (scaffold customize.env + overlay/ + depends/), download,
        image, flash, authorize (bake ssh key into ./overlay); maintain over ssh:
        update (push overlay + install depends + apt full-upgrade), ssh, network,
        nmtui, screen, factory-reset, overlay-commit, reboot, poweroff
    [x] reorient the makefile around cargo build/test of the binary; the e2e
        scenarios build images THROUGH the binary. removed the user-facing make
        targets (they are binary subcommands now)
    [x] dropped the now-dead bootfs/userconf.txt (stale credential, never injected)
    [x] docs: README/CONTRIBUTING/DESIGN/tests rewritten for the `raspi-provision
        <cmd>` workflow + the downstream-project layout (overlay/ + depends/ +
        customize.env)
[ ] virtual gadget-mode test (usb0 RNDIS via out-of-tree dummy_hcd, DKMS)
[ ] virtual wifi hotspot test (wlan via mac80211_hwsim, generic-kernel lane)
[x] power-outage resilience (validated via `make test-resilience`)
    [x] phase 1: reduce root writes (journald volatile, no swap, mask
        apt-daily/man-db timers; noatime already stock; keep fstrim)
    [x] phase 2a: ship overlay premount script + modules entry in rootfs/
    [x] phase 2b: carve a 3rd ext4 partition (label persist) from shrunk rootfs
    [x] phase 2c: on-device overlay enablement (build -overlay initramfs,
        edit config.txt/cmdline.txt) via `make overlay`
    [x] phase 2d: ephemeral shape -- tmpfs upper + bind-mount persisted paths
        (ssh host keys, machine-id, NM connections, /home) from persist
    [x] phase 2e: persistent shape -- persist partition as the overlay upper
    [x] phase 2f: qemu harness support (-initrd, build initramfs in-guest)
[x] factory reset (validated via `make test-resilience`)
    [x] bake pristine snapshot of persisted state to /persist/factory/
    [x] reset (from initramfs): discard upper / restore snapshot, reboot clean
    [x] trigger: boot-partition flag file (/boot/firmware/factory-reset)
    [x] trigger: GPIO button held at boot (opt-in, hardware-only; sustained
        hold required so a floating/emulated pin cannot reset-loop)
    [x] trigger: make factory-reset over ssh
    [x] qemu test: enable overlay -> assert overlay root + persistence + reset
```
