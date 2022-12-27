#!/usr/bin/env bash
set -o errexit -o pipefail -o noclobber -o nounset

# Create an aarch64 Arch Linux Arm vm in one click.
# adapted from: https://gist.github.com/thalamus/561d028ff5b66310fac1224f3d023c12

########################################
# Change variables in this section
#
# Directory, relative to script, where machine will be created
INSTALL_DIR=archlinuxarm
#
# Disk size in GB, bare install is about 1.5G
DISK_SIZE=6
#
# Don't change anything below here 
########################################

_STEP=1

step () {
    echo -e "$(tput setaf 20)Step ${_STEP}$(tput setaf 9) => $(tput setaf 20)${1}$(tput sgr0)"
    ((_STEP++))
}

create_install_dir () {
    step "Creating install directory $INSTALL_DIR"
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "$INSTALL_DIR already exists, exiting"
        exit 1
    fi
    if mkdir "$INSTALL_DIR"; then
        echo "$INSTALL_DIR created"
    fi
    cd $INSTALL_DIR
    pushd . > /dev/null
}

EFIPART=""
ROOTPART=""

download_media () {
    step "Downloading install media"
    wget --quiet --show-progress http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
}

set_up_uefi () {
    step "Create UEFI files"
    dd if=/dev/zero of=flash1.img bs=1M count=64
    dd if=/dev/zero of=flash0.img bs=1M count=64
    dd if=/usr/share/edk2/aarch64/QEMU_EFI.fd of=flash0.img conv=notrunc
}

create_and_fdisk () {
    step "Create and format virtual HD (${DISK_SIZE}GB)"
    qemu-img create -f raw arch.raw ${DISK_SIZE}G
    
    (
    echo g      # GPT partition table
    echo n      # new partition
    echo        # default number 1
    echo        # default start sector
    echo +256M  # 256M EFI partition
    echo t      # type
    echo 1      # EFI system partition
    echo n      # new partition
    echo        # default number
    echo        # default first sector
    echo        # use entire disk
    echo w      # write the partition table
    ) | sudo fdisk arch.raw > /dev/null
}

get_loop_dev () {
    step "Map drive partitions"
    while read -r out;
    do
        STR=$(awk '{print $3}' <<< "$out")
        if [ "${STR: -1}" == 1 ]; then
            EFIPART="/dev/mapper/$STR"
            echo "EFIPART  = $EFIPART"
        fi
        if [ "${STR: -1}" == 2 ]; then
            ROOTPART="/dev/mapper/$STR"
            echo "ROOTPART = $ROOTPART"
        fi;    
    done < <(sudo kpartx -av arch.raw)
}

format_mount_populate () {
    step "Format, mount, and populate hard drive partitions"
    sudo mkfs.vfat "$EFIPART"
    sudo mkfs.ext4 "$ROOTPART"
    
    sudo mkdir root
    sudo mount "$ROOTPART" root
    
    sudo mkdir root/boot
    sudo mount "$EFIPART" root/boot
    
    sudo bsdtar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C root
}

set_up_image () {
    step "Create files for first boot configuration"
    BOOTUUID="$(sudo blkid $EFIPART|awk '{print $3}'|cut -b 7-15)"
    ROOTUUID="$(sudo blkid $ROOTPART|awk '{print $2}'|cut -b 7-42)"
    
    sudo rm root/etc/fstab
cat << EOF > tmp
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
/dev/disk/by-uuid/$ROOTUUID / ext4 defaults 0 0
/dev/disk/by-uuid/$BOOTUUID /boot vfat defaults 0 0
EOF

    sudo mv tmp root/etc/fstab
    sudo chown root:root root/etc/fstab

    echo "Image root=UUID=$ROOTUUID rw initrd=\initramfs-linux.img" > tmp
    sudo mv tmp root/boot/startup.nsh

cat << EOFF > tmp
#!/bin/sh
pacman-key --init
pacman-key --populate archlinuxarm
pacman --noconfirm -Syu efibootmgr
efibootmgr --disk /dev/vda --part 1 --create --label "Arch Linux ARM" --loader /Image --unicode 'root=UUID=$ROOTUUID rw initrd=\initramfs-linux.img audit=0' --verbose
systemctl disable setup.service
shutdown -h now
EOFF

    sudo mv tmp root/root/setup.sh
    sudo chown root:root root/root/setup.sh
    sudo chmod 755 root/root/setup.sh
    
cat << SYSD > tmp
[Unit]
Description=Initial setup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/root/setup.sh

[Install]
WantedBy=multi-user.target
SYSD

    sudo mv tmp root/etc/systemd/system/setup.service
    sudo chown root:root root/etc/systemd/system/setup.service
    sudo chmod 644 root/etc/systemd/system/setup.service
    
    cd root/etc/systemd/system/multi-user.target.wants/
    sudo ln -s ../setup.service .
}

cleanup () {
    step "Clean up: umount, remove files"
    popd > /dev/null
    sudo umount root/boot
    sudo umount root
    sudo kpartx -d arch.raw
    sudo rmdir root
    rm ArchLinuxARM-aarch64-latest.tar.gz
    sync
    sync
}

convert_image () {
    step "Convert HD image from raw to qcow2"
    if qemu-img convert -p -O qcow2 arch.raw arch.qcow2; then
        rm arch.raw
    fi
}

set_up_run () {
cat << RUN > run.sh
#!/bin/sh

function run_machine () {
    qemu-system-aarch64 \
        -M virt \
        -nodefaults \
        -nographic \
        -m 1024 \
        -smp 2 \
        -enable-kvm \
        -cpu host,pmu=off \
        -device virtio-rng-pci \
        -device qemu-xhci,id=xhci \
        -serial mon:stdio \
        -drive "if=pflash,media=disk,id=drive0,file=flash0.img,cache=writethrough,format=raw,readonly=on" \
        -drive "if=pflash,media=disk,id=drive1,file=flash1.img,cache=writethrough,format=raw" \
        -drive "if=virtio,media=disk,id=drive2,file=arch.qcow2,cache=writethrough,format=qcow2" \
        -nic user,model=virtio-net-pci
}

run_machine
RUN

    chmod 755 run.sh
}

create_install_dir

download_media

set_up_uefi

create_and_fdisk

get_loop_dev

format_mount_populate

set_up_image

cleanup

convert_image

set_up_run

step "Starting machine in 10 seconds.\n \
      Use ctrl+a, c to access muxed monitor.\n \
      \"quit\" in the monitor will kill the vm.\n \
      First boot will take a while, subsequent boots\n \
      will be much faster."

sleep 10

./run.sh

step "All done. To run your new machine, cd ${INSTALL_DIR},\n \
      ./run.sh"

exit 0
