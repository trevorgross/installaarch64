# Create an aarch64 Arch Linux Arm vm in one click.

Create an [Arch Linux Arm](https://archlinuxarm.org/) [qemu](https://www.qemu.org/) VM in one click.

Intended for use on an aarch64 host, but could easily be adapted for e.g. x86_64 hosts.

This script sets up an aarch64 qemu vm with a hard drive and UEFI, downloads the latest Arch Linux Arm aarch64 release, and installs it. See [here](https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-4), "Installation" tab, for more info about the image that's installed.

Then it boots the VM, does a full system upgrade, and configures the UEFI boot device. This boot takes a _long_ time, because it waits for PXE. Subsequent boots are faster. The actual updates once booted depend on your Internet speed, but they take a little while. Just be patient and wait for the machine to shut off.

You can log in during this first boot, but be advised the VM will shut down on its own. Serial monitor and qemu monitor are muxed to the console, use Ctrl+a, c to toggle between them. 

The script doesn't have much error or dependency checking. Makes liberal use of `sudo`. Only tested on an Arch Linux Arm host on a Raspberry Pi 4.

Note that UEFI and qemu packaging on Arch Linux Arm is a bit messy right now. See [this forum thread](https://archlinuxarm.org/forum/viewtopic.php?f=15&t=16289), for example. But if you can get `qemu-system-aarch64` installed and running, try this script!
