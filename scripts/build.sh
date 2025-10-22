#!/bin/bash

set -eo pipefail

ARCH="$(uname -m)"
OS="${OS:-ubuntu}"
LABEL="$(echo $OS | tr '[:lower:]' '[:upper:]')"

[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

KERNEL="build/image/linux/${ARCH}"
INITRD="build/image/linux/${ARCH}/initrd.img"
SUITE="noble"
VERSION="24.04"
VERSION_FULL="${VERSION}.2"

BUILD="build/image/${OS}/${ARCH}"
FS="${BUILD}/filesystem.img"

UUID=$(dd if=/dev/urandom bs=1 count=100 2>/dev/null | tr -dc 'a-z0-0' | cut -c -6)

BOOTDATA="bpool/IBOOT"
ROOTDATA="rpool/IROOT"
USERDATA="rpool/IUSERDATA"

SCRIPTSDIR="scripts/buildimg"

[[ "$OS" == "ubuntu" ]] &&
  BASE="https://cdimage.ubuntu.com/ubuntu-base/releases/$SUITE/release/ubuntu-base-${VERSION_FULL}-base-${ARCH}.tar.gz"

# source installer
. scripts/buildimg/installer/lib/init
. scripts/buildimg/installer/storage/init
. scripts/buildimg/installer/bootloader/init

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Create build directory if it doesn't exist
mkdir -p "$BUILD"

# install packages
if [[ ! -f "/tmp/.packages_installed" ]]; then
  sudo ./scripts/buildimg/packages.sh
  sudo apt-get install -y binwalk xorriso
fi

result=$?
if [[ $result -eq 0 ]]; then
  touch "/tmp/.packages_installed"
fi

# create filesystem image only if it doesn't exist
create_fs_image "$FS" "$OS"

# create rootfs only if it doesn't exist
extract_rootfs "$BASE"

# add content to the filesystem
add_filesystem_content

ls -l /tmp/.build_configured >/dev/null || {
  scripts/buildimg/initfs.sh
  sudo -E chroot /mnt /usr/bin/env ARCH=$ARCH OS=$OS UUID=$UUID BOOTDATA=$BOOTDATA ROOTDATA=$ROOTDATA USERDATA=$USERDATA bash -l <<EOF
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export DEBIAN_FRONTEND=noninteractive
    export LANG=C
    export LANGUAGE=C
    export LC_ALL=C

    export SCRIPTSDIR=/tmp

    # source installer
    . /tmp/installer/lib/init
    . /tmp/installer/storage/init
    . /tmp/installer/bootloader/init

    set_resolv_conf
    write_fstab

    # install packages
    stat /tmp/packages.sh && /tmp/packages.sh

    # FIXME: install kernel
    install_kernel "$VERSION"

    create_users "$OS"
    disable_log_compression
    fix_filesystem_mount_ordering $BOOTDATA $ROOTDATA $OS

    # configure
    /tmp/configure.sh
    /tmp/motd.sh

    # cleanup
    apt autoremove -y --purge
    apt clean -y
    rm -rf /etc/netplan/* /var/cache/apt/* /var/lib/apt/lists/* /tmp/* ~/.bash_history
    echo -n >/etc/machine-id
    history -c
EOF
  touch /tmp/.build_configured
}

# create tar package (for target)
if [[ ! -f "${BUILD}/image/repo/${OS}-${ARCH}.tar" ]]; then
  echo "Creating tar package..."

  for d in dev/pts sys/firmware/efi/efivars; do mountpoint -q "/mnt/$d" && sudo -E umount "/mnt/$d"; done
  mountpoint -q /mnt/boot/grub && sudo umount /mnt/boot/grub
  mountpoint -q /mnt/boot/efi && sudo umount /mnt/boot/efi
  for d in dev proc sys run tmp; do mountpoint -q "/mnt/$d" && sudo -E umount "/mnt/$d"; done

  mkdir -p "${BUILD}/image/install/repo"
  sudo -E tar --numeric-owner -cf "${BUILD}/image/install/repo/${OS}-${ARCH}.tar" -C /mnt .
else
  echo "Tar package already exists, skipping..."
fi

ls -l /tmp/.installer_configured >/dev/null || {
  sudo cp -rf scripts/buildimg/installer "/mnt/tmp/installer"
  scripts/buildimg/initfs.sh
  sudo -E chroot /mnt /usr/bin/env ARCH=$ARCH OS=$OS LABEL=$LABEL BUILD=$BUILD FS=$FS bash -l <<EOF
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export DEBIAN_FRONTEND=noninteractive
    export LANG=C
    export LANGUAGE=C
    export LC_ALL=C

    export SCRIPTSDIR=/tmp

    # source installer
    . /tmp/installer/lib/init
    . /tmp/installer/storage/init
    . /tmp/installer/bootloader/init

    setup_serial_getty_override
    ln -sf /etc/systemd/system/serial-getty@ttyAMA0.service.d /etc/systemd/system/getty@tty1.service.d

    apt-get update -yq
    apt-get install -y initramfs-tools casper

    # FIXME:
    DEV="$(losetup -l | grep "$FS" | awk '{print $1}')" || DEV="$(losetup -Pf --show "$FS")"

    # install grub-efi
    update-initramfs -u
    install_grub_efi ${DEV}p1 $OS $ARCH
    rm -f /boot/grub/grub.cfg

    # create iso workspace
    mkdir -p "/image/boot/grub" "/image/casper" "/image/install"

    # create base point access file for grub
    touch "/image/${OS}"

    # create isolinux/grub.cfg only if it doesn't exist
    create_isolinux_grub_cfg "$LABEL"

    # copy kernel and initrd
    cp /boot/vmlinuz-* /image/casper/vmlinuz
    cp /boot/initrd.img-* /image/casper/initrd.img

    # generate manifest
    generate_manifest $OS

    # cleanup
    apt-get autoremove -y --purge
    apt-get clean -y
    rm -rf /etc/netplan/* /var/cache/apt/* /var/lib/apt/lists/* /tmp/* ~/.bash_history
    history -c
EOF
  touch /tmp/.installer_configured
}

# copy memtest86+ binary (BIOS and UEFI) only if not already present
if [[ ! -f "/mnt/image/install/memtest86+.bin" ]]; then
  echo "Downloading memtest86+..."
  curl -fsSLo /tmp/memtest86.zip https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip
  unzip -p /tmp/memtest86.zip memtest64.bin | sudo tee /mnt/image/install/memtest86+.bin >/dev/null
  unzip -p /tmp/memtest86.zip memtest64.efi | sudo tee /mnt/image/install/memtest86+.efi >/dev/null
else
  echo "memtest86+ already present, skipping download..."
fi

# add installer scripts
sudo cp -r scripts/buildimg/installer/* "/mnt/image/install/"

# FIXME: compress chroot (only for live image)
if [[ ! -f "${BUILD}/image/casper/filesystem.squashfs" ]]; then
  echo "Compressing chroot to squashfs..."

  [[ -d /mnt/image ]] && {
    [[ -d "${BUILD}/image" ]] && rm -rf "${BUILD}/image"
    sudo mv /mnt/image "${BUILD}/image"
  }

  for d in dev/pts sys/firmware/efi/efivars; do mountpoint -q "/mnt/$d" && sudo -E umount "/mnt/$d"; done
  mountpoint -q /mnt/boot/grub && sudo umount /mnt/boot/grub
  mountpoint -q /mnt/boot/efi && sudo umount /mnt/boot/efi
  for d in dev proc sys run tmp; do mountpoint -q "/mnt/$d" && sudo -E umount "/mnt/$d"; done

  # [[ -f "${BUILD}/image/casper/filesystem.squashfs" ]] && rm -f "${BUILD}/image/casper/filesystem.squashfs"
  sudo -E mksquashfs /mnt "${BUILD}/image/casper/filesystem.squashfs" -comp xz
  # sudo -E mksquashfs /mnt "${BUILD}/image/casper/filesystem.squashfs" \
  #   -b 1M \
  #   -comp xz \
  #   -e "root/.*" \
  #   -e "root/*" \
  #   -e "run/*" \
  #   -e "swapfile" \
  #   -e "tmp/.*" \
  #   -e "tmp/*" \
  #   -e "var/cache/apt/archives/*" \
  #   -no-duplicates \
  #   -no-recovery \
  #   -noappend \
  #   -wildcards \
  #   -Xdict-size 100%
else
  echo "Squashfs already exists, skipping..."
fi

# create filesystem size file
printf "$(sudo du -sx --block-size=1 /mnt | cut -f 1)" | sudo tee "${BUILD}/image/casper/filesystem.size" >/dev/null

# generate md5sum.txt
(
  cd "${BUILD}/image"
  /bin/bash -c "(sudo find . -type f -print0 | xargs -0 md5sum | grep -v -e 'isolinux' | sudo tee md5sum.txt >/dev/null)"
)

# create iso image for livecd
(
  CURDIR="$(pwd)"
  # INITRD="$(mktemp -d /tmp/initrd.XXXXXX)"
  # unmkinitramfs "${BUILD}/image/boot/initrd.img" "$INITRD"
  # cat scripts/buildimg/initramfs >"$INITRD/main/init"
  # cd "$INITRD"
  # find . | cpio -H newc -o | gzip -9 > "${CURDIR}/${BUILD}/image/boot/initrd.img"
  grub-mkrescue -o "${CURDIR}/build/image/${OS}-${ARCH}.iso" "${CURDIR}/${BUILD}/image/"
)

# TODO: create onie installer
# TODO: create qemu image

echo "Build completed successfully."
