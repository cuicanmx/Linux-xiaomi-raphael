#!/usr/bin/env bash
set -euo pipefail

# 检查root权限
[[ $(id -u) -eq 0 ]] || { echo "需要root权限" >&2; exit 1; }

# 检查参数
[[ $# -ge 2 ]] || { echo "用法: $0 <变体> <内核版本>" >&2; exit 1; }

DISTRO_ARG="$1"
KERNEL_VERSION="$2"

IFS='-' read -r DISTRO_TYPE DISTRO_VARIANT <<< "$DISTRO_ARG"

case "$DISTRO_TYPE" in
    ubuntu)
        DISTRO_VERSION="noble"
        MIRROR="http://ports.ubuntu.com/ubuntu-ports/"
        ;;
    *) echo "不支持的发行版: $DISTRO_TYPE" >&2; exit 1 ;;
esac

# 配置
IMAGE_SIZE="6G"
ROOT_PASSWORD="1234"
HOSTNAME="xiaomi-raphael"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

BASE_PACKAGES="systemd udev dbus bash-completion net-tools systemd-resolved wpasupplicant iw iproute2 sudo openssh-server openssh-client chrony vim wget curl iputils-ping network-manager wireless-regdb alsa-ucm-conf alsa-utils initramfs-tools u-boot-tools ca-certificates"

KERNEL_PACKAGES="linux-xiaomi-raphael firmware-xiaomi-raphael alsa-xiaomi-raphael"

# 检查依赖命令
for cmd in debootstrap mkfs.ext4 mount truncate 7z tune2fs; do
    command -v "$cmd" &>/dev/null || { echo "命令 '$cmd' 未找到" >&2; exit 1; }
done

# 检查内核包
for pkg in $KERNEL_PACKAGES; do
    [[ -f "${pkg}"*.deb ]] || { echo "缺少内核包: ${pkg}*.deb" >&2; exit 1; }
done

# 清理旧环境
[[ -d "rootdir" ]] && {
    mount | grep "rootdir" | awk '{print $3}' | xargs -r umount -l 2>/dev/null || true
    rm -rf rootdir
}
rm -f rootfs.img 2>/dev/null || true

echo "开始构建 $DISTRO_TYPE-$DISTRO_VARIANT..."

# 创建镜像
truncate -s "$IMAGE_SIZE" rootfs.img
mkfs.ext4 rootfs.img
mkdir -p rootdir
mount -o loop rootfs.img rootdir

# debootstrap
debootstrap --arch=arm64 "$DISTRO_VERSION" rootdir "$MIRROR" || { echo "debootstrap 失败" >&2; exit 1; }

# 挂载虚拟文件系统
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# 配置系统
echo 'LC_ALL=C.UTF-8' > rootdir/etc/environment
echo 'LANG=C.UTF-8' >> rootdir/etc/environment
echo "root:$ROOT_PASSWORD" | chroot rootdir chpasswd
echo "$HOSTNAME" > rootdir/etc/hostname
echo -e "127.0.0.1\tlocalhost\n127.0.1.1\t$HOSTNAME" > rootdir/etc/hosts

cat > rootdir/etc/fstab << EOF
PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077 0 0
EOF

# 配置网络
mkdir -p rootdir/etc/systemd/network/
cat > rootdir/etc/systemd/network/10-autodhcp.network << 'EOF'
[Match]
Name=eth* en* wl* wlp* wlan* eno* ens* enp* enx* enP*
[Network]
DHCP=yes
LLDP=yes
EmitLLDP=nearest-bridge
IPv6AcceptRA=yes
[DHCP]
UseMTU=true UseDNS=true UseHostname=false
EOF

chroot rootdir systemctl disable networking.service 2>/dev/null || true
chroot rootdir systemctl enable systemd-networkd

# 配置SSH
if [[ "$DISTRO_VARIANT" != *"desktop"* ]]; then
    cat > rootdir/etc/ssh/sshd_config << 'EOF'
ListenAddress 0.0.0.0
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
    chroot rootdir systemctl enable ssh
fi

# 安装包
chroot rootdir apt update || { echo "更新包列表失败" >&2; exit 1; }
chroot rootdir apt install -y --no-install-recommends $BASE_PACKAGES || { echo "安装包失败" >&2; exit 1; }
chroot rootdir systemctl enable chrony

# 安装桌面
if [[ "$DISTRO_VARIANT" == "desktop" ]]; then
    chroot rootdir apt install -y ubuntu-desktop || true
    mkdir -p rootdir/var/lib/gdm
    touch rootdir/var/lib/gdm/run-initial-setup
    chroot rootdir systemctl set-default graphical.target
fi

# 安装内核包
for pkg in $KERNEL_PACKAGES; do
    cp "${pkg}"*.deb rootdir/tmp/
done
for pkg in $KERNEL_PACKAGES; do
    chroot rootdir dpkg -i "/tmp/${pkg}.deb" || echo "$pkg 安装失败，跳过"
done
chroot rootdir update-initramfs -c -k all

# 生成boot镜像
if [[ "$DISTRO_VARIANT" == "server" ]]; then
    wget -q --timeout=30 https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img || echo "boot镜像下载失败，跳过"
    if [[ -f "xiaomi-k20pro-boot.img" ]] && [[ -d "rootdir/boot" ]]; then
        mkdir -p boot_tmp
        if mount -o loop xiaomi-k20pro-boot.img boot_tmp 2>/dev/null; then
            [[ -d "rootdir/boot/dtbs/qcom" ]] && cp -r rootdir/boot/dtbs/qcom boot_tmp/dtbs/
            [[ -f "$(ls rootdir/boot/config-* 2>/dev/null | head -1)" ]] && cp "$(ls rootdir/boot/config-* 2>/dev/null | head -1)" boot_tmp/
            [[ -f "$(ls rootdir/boot/initrd.img-* 2>/dev/null | head -1)" ]] && cp "$(ls rootdir/boot/initrd.img-* 2>/dev/null | head -1)" boot_tmp/initramfs
            [[ -f "$(ls rootdir/boot/vmlinuz-* 2>/dev/null | head -1)" ]] && cp "$(ls rootdir/boot/vmlinuz-* 2>/dev/null | head -1)" boot_tmp/linux.efi
            umount boot_tmp 2>/dev/null || true
            rm -rf boot_tmp
            echo "boot镜像生成完成"
        else
            echo "boot镜像挂载失败，跳过"
        fi
    fi
fi

# 清理
chroot rootdir apt clean all
for mp in sys proc dev/pts dev; do
    mountpoint -q "rootdir/$mp" && umount -l "rootdir/$mp" 2>/dev/null || true
done
umount rootdir 2>/dev/null || true
rm -rf rootdir

# 调整UUID
tune2fs -U "$FILESYSTEM_UUID" rootfs.img 2>/dev/null || true

# 打包
OUTPUT_FILE="${DISTRO_TYPE}-${DISTRO_VARIANT}-kernel-${KERNEL_VERSION}.7z"
7z a "$OUTPUT_FILE" rootfs.img || { echo "压缩失败" >&2; exit 1; }

echo "构建完成: $OUTPUT_FILE"
