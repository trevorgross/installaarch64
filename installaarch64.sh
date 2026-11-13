#!/usr/bin/env bash
set -o errexit -o pipefail -o noclobber -o nounset

if [[ $(id -u) -ne 0 ]]; then
    echo "Run this as root only."
    exit 2
fi

# trap "exit" INT TERM
# trap "undo" EXIT

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

URL="http://os.archlinuxarm.org/os/"
FILE="ArchLinuxARM-rpi-aarch64-latest.tar.gz"

EFIPART=""
ROOTPART=""
ROOTUUID=""
MISSING_TOOLS=0

_STEP=1

step () {
    echo -e "$(tput setab 7)$(tput setaf 10)Step ${_STEP} $(tput setaf 0)=>$(tput setaf 12) ${1}$(tput sgr0)"
    ((_STEP++))
}

info () {
    echo -e "$(tput setab 7)$(tput setaf 12)Info   $(tput setaf 0)=>$(tput setaf 12) ${1}$(tput sgr0)"
}

err () {
    echo -e "$(tput setab 7)$(tput setaf 9)Error  $(tput setaf 0)=>$(tput setaf 12) ${1}$(tput sgr0)"
}

check_kpartx () {
    if [[ -n $(kpartx --version 2> /dev/null) ]]; then
        info "Found kpartx"
    else
        err "'kpartx' not found. Install the 'multipath-tools' package"
        MISSING_TOOLS=1
    fi
}

check_dosfstools () {
    if [[ -n $(mkfs.vfat --version 2> /dev/null) ]]; then
        info "Found mkfs.vfat"
    else
        err "'mkfs.vfat' not found. Install the 'dosfstools' package"
        MISSING_TOOLS=1
    fi    
}

check_uefi () {
    if [[ -f "/usr/share/edk2/aarch64/QEMU_EFI.fd" ]]; then
        info "Found UEFI files"
    else
        err "UEFI files are required. Install aarch64 OVMF (not in arm repo):\n \
         download from https://archive.archlinux.org/packages/e/edk2-aarch64/"
        MISSING_TOOLS=1
    fi
}

check_qemu_img () {
    if [[ -n $(qemu-img --version 2> /dev/null) ]]; then
        info "Found qemu-img."
    else
        err "'qemu-img' not found. Install the 'qemu-img' package."
        MISSING_TOOLS=1
    fi
}

run_prog_checks () {
    step "Checking requirements"
    check_kpartx
    check_dosfstools
    check_uefi
    check_qemu_img
    if [[ $MISSING_TOOLS -eq 1 ]]; then
        exit 2
    fi
}

create_install_dir () {
    step "Creating install directory '$INSTALL_DIR'"
    if [[ -d "$INSTALL_DIR" ]]; then
        err "$INSTALL_DIR already exists, exiting"
        exit 1
    fi
    if mkdir "$INSTALL_DIR"; then
        info "'$INSTALL_DIR' created"
    fi
}

download_media () {
    step "Finding install media"
    if [[ ! -f "$FILE" ]]; then
        info "Downloading media..."
        # Arch will have curl
        curl --progress-bar -Lo "${FILE}" "${URL}${FILE}"
    else
        info "Install media found, reusing"
    fi
}

set_up_uefi () {
    step "Copy UEFI files"
    cp /usr/share/edk2/aarch64/QEMU_{EFI,VARS}.fd .
}

create_and_fdisk () {
    step "Create and format virtual HD (${DISK_SIZE}GB)"
    qemu-img create -f raw arch.img ${DISK_SIZE}G
    
    (
    echo o      # delete all partitions
    echo y      # confirm
    echo n      # new partition
    echo        # default number 1
    echo        # default start sector
    echo +1G    # 1G EFI partition
    echo ef00   # EFI partition type
    echo n      # new partition
    echo        # default number 2
    echo        # default start sector
    echo        # default end sector (entire disk)
    echo        # default type (Linux)
    echo w      # write the partition table
    echo y      # confirm write
    ) | gdisk arch.img
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
    done < <(kpartx -av arch.img)
}

format_mount () {
    step "Format and mount hard drive partitions"
    mkfs.vfat -F32 "$EFIPART"
    mkfs.ext4 -F -L root "$ROOTPART"
    
    mkdir root
    mount "$ROOTPART" root
    
    mkdir root/boot
    mount "$EFIPART" root/boot
}

unpack () {
    step "Unpack install files to hard drive"
    bsdtar -xpf "../${FILE}" -C root
    sync
}

set_up_image () {
    step "Create files for first boot configuration"
    BOOTUUID="$(lsblk -noUUID $EFIPART)"
    ROOTUUID="$(lsblk -noUUID $ROOTPART)"
    
    rm root/etc/fstab
cat << EOF > root/etc/fstab
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
UUID=$BOOTUUID  /boot   vfat    defaults    0   0
EOF

    cp root/boot/Image .
    cp root/boot/initramfs-linux.img .

cat <<'EOF' > root/root/setup.sh
#!/bin/sh

pacman-key --init
pacman-key --populate archlinuxarm

PROGS="efibootmgr ethtool gdisk htop inetutils lvm2 nfs-utils nmap openssh sudo tcpdump tmux usbutils vim wget zsh"
pacman --noconfirm -Syu ${PROGS}

ROOT="$(lsblk -noUUID /dev/vda2)"
efibootmgr --disk /dev/vda --part 1 --create --label "Arch Linux ARM" --loader \Image --unicode "root=UUID=$ROOT rw initrd=\initramfs-linux.img" --verbose

ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "\4" >> /etc/issue
echo >> /etc/issue

cat <<EOFF > /etc/profile.d/nice-aliases.sh
alias confgrep="grep -v '^#\|^$'"
alias diff="diff --color=auto"
alias grep="grep --color=auto"
alias ip="ip --color=auto"
alias ls="ls --color=auto"
alias lsd="ls --group-directories-first"
EOFF

USERNAME=ii

mv /home/alarm "/home/${USERNAME}"
groupmod -n "${USERNAME}" alarm
usermod -a -d "/home/${USERNAME}" -G wheel -l "${USERNAME}" -s /bin/zsh alarm

sed -i "s/alarm/$USERNAME/g" /etc/subuid
sed -i "s/alarm/$USERNAME/g" /etc/subgid

cat <<'ENDZSH' > /home/"${USERNAME}"/.zshrc
# https://wiki.archlinux.org/index.php/SSH_keys#SSH_agents
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    ssh-agent > ~/.ssh-agent-running
fi
if [[ "$SSH_AGENT_PID" == "" ]]; then
    eval "$(<~/.ssh-agent-running)"
fi

case $TERM in
    xterm*)
        precmd () {print -Pn "\e]0;%n@%m:%~\a"}
        ;;
esac

eval $(dircolors -b)

export EDITOR="vim"
export HISTFILE=~/.zsh_history
export HISTFILESIZE=1000000000
export HISTSIZE=1000000000
export HISTTIMEFORMAT="%a %b %d %R "
export PROMPT='%B%F{147}%n%f%b@%B%F{108}%m%f%b %B%F{99}%~%f%b %# '
export RPROMPT='%B%F{169}%D{%H:%M:%S}%f%b'
export SAVEHIST=10000
export TERM=xterm-256color
export VISUAL="vim"

setopt INC_APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt CORRECT

bindkey "^A" beginning-of-line
bindkey "^E" end-of-line
bindkey "^R" history-incremental-search-backward
bindkey "^[[3~" delete-char

. /etc/profile.d/nice-aliases.sh
alias bc="bc -l"
alias dmesg="dmesg -T"
alias history="history -i 1"
alias screen="screen -q"
function ccd { mkdir -p "$1" && cd "$1" }
ENDZSH

chown -R "${USERNAME}":"${USERNAME}" /home/"${USERNAME}"

echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopass
chmod 640 /etc/sudoers.d/99-wheel-nopass

l2r () {
    curl -L https://github.com/azlux/log2ram/archive/master.tar.gz | tar zxf -
    cd log2ram-master
    chmod +x install.sh && ./install.sh
    cd ..
    rm -r log2ram-master
}

l2r

systemctl disable setup.service
shutdown -h now
EOF

    chown root:root root/root/setup.sh
    chmod 755 root/root/setup.sh
    
cat << SYSD > root/etc/systemd/system/setup.service
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

    chown root:root root/etc/systemd/system/setup.service
    chmod 644 root/etc/systemd/system/setup.service
    
    pushd .
    cd root/etc/systemd/system/multi-user.target.wants/
    ln -s ../setup.service .
    popd
}

cleanup () {
    step "Clean up: umount, remove files"
    umount root/boot
    umount root
    kpartx -dv arch.img
    rmdir root
    #rm "${FILE}"
    sync
}

undo () {
    err "Something went wrong, bailing out."
    umount root/boot
    umount root
    kpartx -dv arch.img
    sync
}

convert_image () {
    step "Convert HD image from raw to qcow2"
    if qemu-img convert -p -O qcow2 arch.img arch.qcow2; then
        rm arch.img
    fi
}

set_up_run () {
cat << RUN > run.sh
#!/bin/sh

function run_machine () {
    args=(
        -M virt
        -kernel Image
        -initrd initramfs-linux.img
        -append 'root=UUID=$ROOTUUID rw initrd=\initramfs-linux.img'
        -nodefaults
        -nographic
        -m 1024
        -smp 2
        -enable-kvm
        -cpu host
        -device virtio-rng-pci
        -device qemu-xhci,id=xhci
        -serial mon:stdio
        -drive if=pflash,media=disk,id=EFI,file=QEMU_EFI.fd,cache=none,format=raw,readonly=on
        -drive if=pflash,media=disk,id=EFIVARS,file=QEMU_VARS.fd,cache=none,format=raw
        -drive if=virtio,media=disk,id=hda,file=arch.qcow2,cache=none,format=qcow2
        -device virtio-net-pci,netdev=n0
        -netdev user,id=n0,hostfwd=tcp::5555-:22
    )
RUN
cat << 'RUN2' >> run.sh

    qemu-system-aarch64 "${args[@]}"
}

run_machine
RUN2

    chmod 755 run.sh
}

run_prog_checks

create_install_dir

download_media

cd "$INSTALL_DIR"

set_up_uefi

create_and_fdisk

get_loop_dev

format_mount

unpack

set_up_image

cleanup

convert_image

set_up_run

step "Starting machine in 10 seconds.\n \
      Use ctrl+a, c to access muxed monitor.\n \
      \"quit\" in the monitor will kill the vm.\n \
      To run your new machine, cd ${INSTALL_DIR},\n \
      ./run.sh"

I=10
while [[ $I -gt 0 ]]; do
    echo -ne "$(tput setab 7)$(tput setaf 12)  $I  $(tput sgr0)"
    sleep 1
    ((I--))
    printf '\r'
done
echo -e "$(tput setab 7)$(tput setaf 12)  0  $(tput sgr0)"

./run.sh

rm Image
rm initramfs-linux.img
cd ..

exit 0
