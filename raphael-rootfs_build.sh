#!/bin/sh

# if [ "$(id -u)" -ne 0 ]
# then
#   echo "rootfs can only be built as root"
#   exit
# fi

# VERSION="noble"
# UBUNTU_VERSION="24.04.3"

truncate -s 6G rootfs.img
mkfs.ext4 rootfs.img
mkdir rootdir
mount -o loop rootfs.img rootdir

# wget https://cdimage.ubuntu.com/ubuntu-base/releases/$VERSION/release/ubuntu-base-$UBUNTU_VERSION-base-arm64.tar.gz
# tar xzvf ubuntu-base-$UBUNTU_VERSION-base-arm64.tar.gz -C rootdir
# #rm ubuntu-base-$UBUNTU_VERSION-base-arm64.tar.gz
debootstrap --arch=arm64 trixie rootdir http://deb.debian.org/debian/
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
chroot rootdir apt install -y bash-completion sudo apt-utils ssh openssh-server nano systemd-boot initramfs-tools chrony curl wget u-boot-tools-

#Device specific
chroot rootdir apt install -y rmtfs protection-domain-mapper tqftpserv

#Remove check for "*-laptop"
sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service

cp xiaomi-raphael-debs_$2/*-xiaomi-raphael.deb rootdir/tmp/
chroot rootdir dpkg -i /tmp/linux-xiaomi-raphael.deb
chroot rootdir dpkg -i /tmp/firmware-xiaomi-raphael.deb
chroot rootdir dpkg -i /tmp/alsa-xiaomi-raphael.deb
rm rootdir/tmp/*-xiaomi-raphael.deb
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
