#!/bin/bash

set -e

# Check arguments
if [ $# -ne 2 ]; then
    echo "❌ 用法错误: $0 <发行版类型-变体> <内核版本>"
    echo "   示例: $0 debian-server 6.18"
    exit 1
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ rootfs can only be built as root"
    exit 1
fi

echo "🚀 开始构建 $1 发行版，内核版本 $2"
echo "📋 参数检查: distro=$1, kernel=$2"

# Parse distribution and variant
distro_type=$(echo "$1" | cut -d'-' -f1)
distro_variant=$(echo "$1" | cut -d'-' -f2)

# Set default version based on distribution type
if [ "$distro_type" = "debian" ]; then
    distro_version="trixie"  # Debian 13 (trixie)
elif [ "$distro_type" = "ubuntu" ]; then
    distro_version="noble"   # Ubuntu 24.04 (noble)
else
    echo "❌ 错误: 不支持的发行版类型: $distro_type"
    exit 1
fi

echo "🔍 解析发行版信息:"
echo "  类型: $distro_type"
echo "  变体: $distro_variant"
echo "  版本: $distro_version (默认)"
echo "  内核: $2"

# Check required kernel packages
echo "📦 检查内核包文件..."
# 使用兼容的shell语法检查包文件
found_packages=0
missing_packages=""

# 检查每个包文件（使用不带版本号的文件名）
if ls linux-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    echo "✅ 找到: linux-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="linux-xiaomi-raphael*.deb $missing_packages"
    echo "❌ 未找到: linux-xiaomi-raphael*.deb"
fi

if ls firmware-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    echo "✅ 找到: firmware-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="firmware-xiaomi-raphael*.deb $missing_packages"
    echo "❌ 未找到: firmware-xiaomi-raphael*.deb"
fi

if ls alsa-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    echo "✅ 找到: alsa-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="alsa-xiaomi-raphael*.deb $missing_packages"
    echo "❌ 未找到: alsa-xiaomi-raphael*.deb"
fi

if [ $found_packages -lt 3 ]; then
    echo "❌ 错误: 缺少必需的内核包: $missing_packages"
    echo "💡 请确保在工作流中正确下载了内核包"
    echo "📁 当前目录文件列表:"
    ls -la *.deb 2>/dev/null || echo "  没有找到 .deb 文件"
    exit 1
fi

echo "✅ 所有必需的内核包已就绪 ($found_packages/3)"

# Clean up old rootfs and image
echo "🧹 清理旧的rootfs和镜像文件..."
if [ -d "rootdir" ]; then
    umount rootdir/sys 2>/dev/null || true
    umount rootdir/proc 2>/dev/null || true
    umount rootdir/dev/pts 2>/dev/null || true
    umount rootdir/dev 2>/dev/null || true
    umount rootdir 2>/dev/null || true
    rm -rf rootdir
    echo "✅ 旧目录已清理"
fi

if [ -f "rootfs.img" ]; then
    rm -f rootfs.img
    echo "✅ 旧镜像文件已清理"
fi

# Create and mount image file
echo "📁 创建IMG镜像文件..."
truncate -s 6G rootfs.img
mkfs.ext4 rootfs.img
mkdir -p rootdir
mount -o loop rootfs.img rootdir
echo "✅ 6GB镜像文件创建并挂载完成"

# Bootstrap the rootfs
echo "🌱 开始引导系统 (debootstrap)..."
echo "📥 下载: $distro_type $distro_version"

# Set mirror based on distribution type
if [ "$distro_type" = "debian" ]; then
    mirror="http://deb.debian.org/debian/"
elif [ "$distro_type" = "ubuntu" ]; then
    mirror="http://ports.ubuntu.com/ubuntu-ports/"
fi

echo "🔗 使用镜像源: $mirror"

if sudo debootstrap --arch=arm64 "$distro_version" rootdir "$mirror"; then
    echo "✅ 系统引导完成"
else
    echo "❌ debootstrap 失败"
    echo "💡 请检查网络连接和镜像源可用性"
    exit 1
fi

# Mount proc, sys, dev
echo "🔗 挂载虚拟文件系统..."
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount --bind /proc rootdir/proc
mount --bind /sys rootdir/sys
echo "✅ 虚拟文件系统挂载完成"

# Install base packages
echo "📦 安装基础系统包..."
if chroot rootdir apt -qq update; then
    echo "✅ 软件包列表更新完成"
else
    echo "❌ 软件包列表更新失败"
    exit 1
fi

echo "🔧 安装系统工具包..."
if chroot rootdir apt install -qq -y systemd systemd-sysv init udev dbus alsa-ucm-conf; then
    echo "✅ 系统工具包安装完成"
else
    echo "❌ 系统工具包安装失败"
    exit 1
fi

# Install device-specific packages
echo "📱 安装设备特定包..."

# Copy kernel packages to chroot environment
echo "📦 复制内核包到 chroot 环境..."
cp linux-xiaomi-raphael*.deb rootdir/tmp/
cp firmware-xiaomi-raphael*.deb rootdir/tmp/
cp alsa-xiaomi-raphael*.deb rootdir/tmp/
echo "✅ 内核包复制完成"

# Install custom kernel packages
echo "🔧 安装定制内核包..."
if chroot rootdir dpkg -i /tmp/linux-xiaomi-raphael.deb; then
    echo "✅ linux-xiaomi-raphael 安装完成"
else
    echo "❌ linux-xiaomi-raphael 安装失败"
    exit 1
fi

if chroot rootdir dpkg -i /tmp/firmware-xiaomi-raphael.deb; then
    echo "✅ firmware-xiaomi-raphael 安装完成"
else
    echo "❌ firmware-xiaomi-raphael 安装失败"
    exit 1
fi

if chroot rootdir dpkg -i /tmp/alsa-xiaomi-raphael.deb; then
    echo "✅ alsa-xiaomi-raphael 安装完成"
else
    echo "❌ alsa-xiaomi-raphael 安装失败"
    exit 1
fi

echo "✅ 所有设备特定包安装完成"

# Create fstab
echo "📋 创建文件系统表..."
echo "PARTLABEL=linux / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=esp /boot/efi vfat umask=0077 0 1" | tee rootdir/etc/fstab

# Create GDM directory
mkdir -p rootdir/var/lib/gdm
touch rootdir/var/lib/gdm/run-initial-setup

# Clean package cache
echo "🧹 清理软件包缓存..."
chroot rootdir apt -qq clean

# Set root password
echo "🔐 设置root密码..."
echo -e "1234\n1234" | sudo chroot rootdir passwd root > /dev/null 2>&1
echo "✅ Root密码已设置为: 1234"

# Network and system configuration
echo "🔧 配置网络和系统设置..."
echo "nameserver 223.5.5.5" | tee rootdir/etc/resolv.conf
echo "xiaomi-raphael" | tee rootdir/etc/hostname
echo "127.0.0.1 localhost
127.0.1.1 xiaomi-raphael" | tee rootdir/etc/hosts
echo "✅ 网络和主机名配置完成"

# Install desktop environment for desktop variants
if [ "$distro_variant" = "desktop" ]; then
    echo "🖥️ 安装桌面环境..."
    chroot rootdir apt -qq update
    if [ "$distro_type" = "debian" ]; then
        echo "🎨 安装Xfce桌面环境..."
        if chroot rootdir apt install -qq -y xfce4 xfce4-goodies; then
            echo "✅ Xfce桌面环境安装完成 (Debian)"
        else
            echo "❌ Xfce桌面环境安装失败"
            exit 1
        fi
    elif [ "$distro_type" = "ubuntu" ]; then
        echo "🎨 安装Ubuntu桌面环境..."
        if chroot rootdir apt install -qq -y ubuntu-desktop-minimal; then
            echo "✅ Ubuntu桌面环境安装完成"
        else
            echo "❌ Ubuntu桌面环境安装失败"
            exit 1
        fi
    fi
fi

# Unmount filesystems
echo "🔓 卸载虚拟文件系统..."
umount rootdir/sys
umount rootdir/proc
umount rootdir/dev/pts
umount rootdir/dev
umount rootdir
echo "✅ 虚拟文件系统卸载完成"

# Clean up directory
rm -d rootdir
echo "✅ 临时目录清理完成"
echo "🔧 调整文件系统UUID..."
tune2fs -U ee8d3593-59b1-480e-a3b6-4fefb17ee7d8 rootfs.img
echo "✅ 文件系统UUID调整完成"
echo "检查目录下文件..."
ls 
# Create 7z archive
echo "🗜️ 创建压缩包..."
output_file="raphael-${distro_type}-${distro_variant}-$2.7z"
if 7z a "${output_file}" rootfs.img; then
    echo "✅ 压缩包创建成功: ${output_file}"
    echo "📊 文件大小: $(du -h "${output_file}" | cut -f1)"
else
    echo "❌ 压缩包创建失败"
    exit 1
fi

echo "🎉 $distro_type-$distro_variant IMG镜像构建完成！"
echo "💡 引导命令行: root=PARTLABEL=linux"