#!/usr/bin/env bash
set -o errexit -o pipefail -o noclobber -o nounset

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
MISSING_TOOLS=0
STARTDIR=$(pwd)

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
    if [[ -n "$(kpartx --version 2> /dev/null)" ]]; then
        info "Found kpartx"
    else
        err "'kpartx' not found. Install the 'multipath-tools' package"
        MISSING_TOOLS=1
    fi
}

check_dosfstools () {
    if [[ -n "$(mkfs.vfat --version 2> /dev/null)" ]]; then
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
         download https://archive.archlinux.org/packages/e/edk2-aarch64/edk2-aarch64-202311-1-any.pkg.tar.zst\n \
         $ sudo pacman -U edk2-aarch64-202311-1-any.pkg.tar.zst"
        exit 2
    fi
}

run_prog_checks () {
    step "Checking requirements"
    check_kpartx
    check_dosfstools
    check_uefi
    if [[ MISSING_TOOLS -eq 1 ]]; then
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
    echo +512M  # 512M EFI partition
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

format_mount () {
    step "Format and mount hard drive partitions"
    sudo mkfs.vfat "$EFIPART"
    sudo mkfs.ext4 "$ROOTPART"
    
    sudo mkdir root
    sudo mount "$ROOTPART" root
    
    sudo mkdir root/boot
    sudo mount "$EFIPART" root/boot
}

unpack () {
    step "Unpack install files to hard drive"
    sudo bsdtar -xpf "../${FILE}" -C root
    sync
}

set_up_image () {
    step "Create files for first boot configuration"
    BOOTUUID="$(sudo blkid -s UUID -o value $EFIPART)"
    ROOTUUID="$(sudo blkid -s UUID -o value $ROOTPART)"
    
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

    echo "Image root=UUID=$ROOTUUID rw initrd=\initramfs-linux.img audit=0" > tmp
    sudo mv tmp root/boot/startup.nsh

cat <<'EOF' > tmp
#!/bin/sh

pacman-key --init
pacman-key --populate archlinuxarm

PROGS="efibootmgr ethtool gdisk htop inetutils linux-headers lvm2 nfs-utils nmap openssh sudo tcpdump tmux usbutils vim wget zsh"
pacman --noconfirm -Syu ${PROGS}

ROOT="$(blkid -s UUID -o value /dev/vda2)"
efibootmgr --disk /dev/vda --part 1 --create --label "Arch Linux ARM" --loader \Image --unicode "root=UUID=$ROOT rw initrd=\initramfs-linux.img audit=0" --verbose

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

usermod -l "${USERNAME}" alarm
usermod -d "/home/${USERNAME}" "${USERNAME}"
groupmod -n "${USERNAME}" alarm

sed -i 's/alarm/ii/g' /etc/subuid
sed -i 's/alarm/ii/g' /etc/subgid

chsh -s /bin/zsh "${USERNAME}"

(
echo asdf
echo asdf
) | passwd "${USERNAME}" > /dev/null

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
export PROMPT='%B%F{47}%n%f%b@%B%F{208}%m%f%b %B%F{199}%~%f%b %# '
export RPROMPT='%B%F{69}%D{%H:%M:%S}%f%b'
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

systemctl disable setup.service
shutdown -h now
EOF

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
    sudo umount root/boot
    sudo umount root
    sudo kpartx -d arch.raw
    sudo rmdir root
    #rm "${FILE}"
    sync
}

undo () {
    err "Something went wrong, bailing out."
    sudo umount root/boot
    sudo umount root
    sudo kpartx -d arch.raw
    sync
}

convert_image () {
    step "Convert HD image from raw to qcow2"
    if qemu-img convert -p -O qcow2 arch.raw arch.qcow2; then
        rm arch.raw
    fi
}

set_up_run () {
cat << 'RUN' > run.sh
#!/bin/sh

function run_machine () {
    args=(
        -M virt
        -nodefaults
        -nographic
        -m 1024
        -smp 2
        -enable-kvm
        -cpu host,pmu=off
        -device virtio-rng-pci
        -device qemu-xhci,id=xhci
        -serial mon:stdio
        -drive if=pflash,media=disk,id=drive0,file=flash0.img,cache=none,format=raw,readonly=on
        -drive if=pflash,media=disk,id=drive1,file=flash1.img,cache=none,format=raw
        -drive if=none,media=disk,id=drive2,file=arch.qcow2,cache=none,format=qcow2
        -device virtio-blk,drive=drive2,id=hd0,bootindex=1
        -device virtio-net-pci,netdev=n0
        -netdev user,id=n0,hostfwd=tcp::5555-:22
    )

    qemu-system-aarch64 "${args[@]}"
}

run_machine
RUN

    chmod 755 run.sh
}

run_prog_checks

create_install_dir

download_media

cd "$INSTALL_DIR"
pushd . > /dev/null

set_up_uefi

create_and_fdisk

get_loop_dev

format_mount

unpack

set_up_image

popd > /dev/null

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

exit 0
