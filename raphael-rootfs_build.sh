#!/bin/sh

# if [ "$(id -u)" -ne 0 ]
# then
#   echo "rootfs can only be built as root"
#   exit
# fi

# Parse distribution and version
distro_type=$(echo $1 | cut -d'-' -f1)
distro_variant=$(echo $1 | cut -d'-' -f2)

truncate -s 6G rootfs.img
mkfs.ext4 rootfs.img
mkdir rootdir
mount -o loop rootfs.img rootdir

# Choose base system based on distribution
case "$distro_type" in
    "debian")
        debootstrap --arch=arm64 trixie rootdir http://deb.debian.org/debian/
        ;;
    "ubuntu")
        debootstrap --arch=arm64 noble rootdir http://ports.ubuntu.com/ubuntu-ports/
        ;;
    *)
        echo "Unsupported distribution: $distro_type"
        exit 1
        ;;
esac
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount --bind /proc rootdir/proc
mount --bind /sys rootdir/sys

echo "nameserver 1.1.1.1" | tee rootdir/etc/resolv.conf
echo "xiaomi-raphael" | tee rootdir/etc/hostname
echo "127.0.0.1 localhost
127.0.1.1 xiaomi-raphael" | tee rootdir/etc/hosts

#chroot installation
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
export DEBIAN_FRONTEND=noninteractive

chroot rootdir apt update
chroot rootdir apt upgrade -y

#u-boot-tools breaks grub installation
chroot rootdir apt install -y bash-completion sudo apt-utils ssh openssh-server nano initramfs-tools chrony curl wget u-boot-tools-

# Install systemd-boot only for Debian
if [ "$distro_type" = "debian" ]; then
    chroot rootdir apt install -y systemd-boot
fi

#Device specific packages (install if available)
chroot rootdir apt install -y rmtfs protection-domain-mapper tqftpserv || true

#Remove check for "*-laptop" if pd-mapper.service exists
if [ -f "rootdir/lib/systemd/system/pd-mapper.service" ]; then
    sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service
fi

# Set root password to 1234
echo 'root:1234' | chroot rootdir chpasswd

# Enable SSH for server variants
if [ "$distro_variant" = "server" ]; then
    chroot rootdir systemctl enable ssh
fi

# Install desktop environment for desktop variants
if [ "$distro_variant" = "desktop" ]; then
    chroot rootdir apt update
    if [ "$distro_type" = "debian" ]; then
        chroot rootdir apt install -y xfce4 xfce4-goodies lightdm
        chroot rootdir systemctl enable lightdm
    elif [ "$distro_type" = "ubuntu" ]; then
        chroot rootdir apt install -y ubuntu-desktop-minimal lightdm
        chroot rootdir systemctl enable lightdm
    fi
fi

# Copy kernel packages to rootfs
if [ -d "xiaomi-raphael-debs_$2" ]; then
    cp xiaomi-raphael-debs_$2/*-xiaomi-raphael.deb rootdir/tmp/
else
    cp *-xiaomi-raphael.deb rootdir/tmp/
fi

# Install kernel packages
chroot rootdir dpkg -i /tmp/linux-xiaomi-raphael.deb || true
chroot rootdir dpkg -i /tmp/firmware-xiaomi-raphael.deb || true

# Install alsa package with dependency resolution
if [ "$distro_type" = "debian" ]; then
    chroot rootdir apt install -y alsa-ucm-conf
elif [ "$distro_type" = "ubuntu" ]; then
    chroot rootdir apt install -y alsa-ucm-conf || chroot rootdir apt install -y alsa-base
fi
chroot rootdir dpkg -i /tmp/alsa-xiaomi-raphael.deb || true

# Clean up kernel packages
rm -f rootdir/tmp/*-xiaomi-raphael.deb
chroot rootdir update-initramfs -c -k all
chroot rootdir rm -rf /boot/dtbs/qcom/
chroot rootdir bash -c "$(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/GengWei1997/kernel-deb/refs/heads/main/ghproxy-Update-kernel.sh)"

#create fstab!
echo "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077 0 1" | tee rootdir/etc/fstab

mkdir rootdir/var/lib/gdm
touch rootdir/var/lib/gdm/run-initial-setup
chroot rootdir apt clean

umount rootdir/sys
umount rootdir/proc
umount rootdir/dev/pts
umount rootdir/dev
umount rootdir

rm -d rootdir

tune2fs -U ee8d3593-59b1-480e-a3b6-4fefb17ee7d8 rootfs.img

echo 'cmdline for legacy boot: "root=PARTLABEL=userdata"'

7z a rootfs.7z rootfs.img
