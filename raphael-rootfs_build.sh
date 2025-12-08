#!/bin/sh

if [ "$(id -u)" -ne 0 ]
then
  echo "rootfs can only be built as root"
  exit
fi

VERSION="noble"
UBUNTU_VERSION="24.04.3"

truncate -s 6G rootfs.img
mkfs.ext4 rootfs.img
mkdir rootdir
mount -o loop rootfs.img rootdir

wget https://cdimage.ubuntu.com/ubuntu-base/releases/$VERSION/release/ubuntu-base-$UBUNTU_VERSION-base-arm64.tar.gz
tar xzvf ubuntu-base-$UBUNTU_VERSION-base-arm64.tar.gz -C rootdir
#rm ubuntu-base-$UBUNTU_VERSION-base-arm64.tar.gz

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount --bind /proc rootdir/proc
mount --bind /sys rootdir/sys

echo "nameserver 1.1.1.1" | tee rootdir/etc/resolv.conf
echo "xiaomi-raphael" | tee rootdir/etc/hostname
echo "127.0.0.1 localhost
127.0.1.1 xiaomi-raphael" | tee rootdir/etc/hosts

if uname -m | grep -q aarch64
then
  echo "cancel qemu install for arm64"
else
  wget https://github.com/multiarch/qemu-user-static/releases/download/v7.2.0-1/qemu-aarch64-static
  install -m755 qemu-aarch64-static rootdir/

  echo ':aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7:\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/qemu-aarch64-static:' | tee /proc/sys/fs/binfmt_misc/register
  #ldconfig.real abi=linux type=dynamic
  echo ':aarch64ld:M::\x7fELF\x02\x01\x01\x03\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\xb7:\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/qemu-aarch64-static:' | tee /proc/sys/fs/binfmt_misc/register
fi


#chroot installation
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
export DEBIAN_FRONTEND=noninteractive

chroot rootdir apt update
chroot rootdir apt upgrade -y

#u-boot-tools breaks grub installation
chroot rootdir apt install -y bash-completion sudo apt-utils ssh openssh-server nano systemd-boot initramfs-tools chrony curl wget u-boot-tools- $1
#chroot rootdir gsettings set org.gnome.shell.extensions.dash-to-dock show-mounts-only-mounted true



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

#EFI
#chroot rootdir apt install -y systemd-boot

#sed --in-place 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' rootdir/etc/default/grub
#sed --in-place 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT=""/' rootdir/etc/default/grub

#this done on device for now
#grub-install
#grub-mkconfig -o /boot/grub/grub.cfg

#create fstab!
echo "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077 0 1" | tee rootdir/etc/fstab

mkdir rootdir/var/lib/gdm
touch rootdir/var/lib/gdm/run-initial-setup

chroot rootdir apt clean

if uname -m | grep -q aarch64
then
  echo "cancel qemu install for arm64"
else
  #Remove qemu emu
  echo -1 | tee /proc/sys/fs/binfmt_misc/aarch64
  echo -1 | tee /proc/sys/fs/binfmt_misc/aarch64ld
  rm rootdir/qemu-aarch64-static
  rm qemu-aarch64-static
fi

# Generated boot

mkdir -p boot_tmp
wget https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img
mount -o loop xiaomi-k20pro-boot.img boot_tmp

cp -r rootdir/boot/dtbs/qcom boot_tmp/dtbs/
cp rootdir/boot/config-* boot_tmp/
cp rootdir/boot/initrd.img-* boot_tmp/initramfs
cp rootdir/boot/vmlinuz-* boot_tmp/linux.efi

umount boot_tmp
rm -d boot_tmp

umount rootdir/sys
umount rootdir/proc
umount rootdir/dev/pts
umount rootdir/dev
umount rootdir

rm -d rootdir

tune2fs -U ee8d3593-59b1-480e-a3b6-4fefb17ee7d8 rootfs.img

echo 'cmdline for legacy boot: "root=PARTLABEL=userdata"'

7z a rootfs.7z rootfs.img
