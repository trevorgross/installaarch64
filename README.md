#Create an aarch64 Arch Linux Arm vm in one click.#

Intended for use on an aarch64 host, but could easily be adapted for e.g. x86_64 hosts.

This script sets up an aarch64 qemu vm with a hard drive and UEFI, downloads the latest Arch Linux Arm aarch64 release, and installs it.

The machine then boots and starts a systemd unit to run a script that does a full system upgrade and configures the UEFI boot device. 

Makes liberal use of `sudo`. 
