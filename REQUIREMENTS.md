# REQUIREMENTS

## provisioning

- provision an RPi4 from an unmodified upstream Raspberry Pi OS image
- update wifi SSID and PSK during `customize`
- SSH access available on first boot without a display or keyboard

## connectivity

- shared connection over RNDIS (USB) enabled by default
- shared connection over ethernet available
- shared connection over wlan (hotspot) available
- each shared connection has its own address/subnet (see README)

## resilience

- the root partition must survive unclean power loss without corruption
- minimize writes to the root partition to reduce flash wear
- device identity and config (ssh host keys, machine-id, NetworkManager
  connections, `/home`) must persist across reboots
- provide a factory reset that restores the device to its provisioned state,
  triggerable headlessly (boot-partition flag, GPIO button, or over ssh)

## testability

- the provisioning flow must be verifiable in a virtual environment that is as
  close to real RPi4 hardware as feasible, without physical hardware
- the virtual environment must boot the same upstream image used on hardware
- the virtual environment must exercise USB host mode
