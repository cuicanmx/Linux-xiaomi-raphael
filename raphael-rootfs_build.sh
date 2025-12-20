#!/bin/bash

set -e

# Check arguments
if [ $# -ne 2 ]; then
    echo "❌ 用法错误: $0 <发行版类型-变体> <内核版本>"
    echo "   示例: $0 debian-server 6.18"
    exit 1
fi

echo "🚀 开始构建 $1 发行版，内核版本 $2"
echo "📋 参数检查: distro=$1, kernel=$2"

distro_type=$(echo "$1" | cut -d'-' -f1)
distro_variant=$(echo "$1" | cut -d'-' -f2)
distro_version=$(echo "$1" | cut -d'-' -f3)

echo "🔍 解析发行版信息:"
echo "  类型: $distro_type"
echo "  变体: $distro_variant"
echo "  版本: $distro_version"
echo "  内核: $2"

# Check required kernel packages
echo "📦 检查内核包文件..."
kernel_packages=("linux-xiaomi-raphael_$2*.deb" "firmware-xiaomi-raphael_$2*.deb" "alsa-xiaomi-raphael_$2*.deb")
missing_packages=()

for pkg in "${kernel_packages[@]}"; do
    if ls $pkg 1> /dev/null 2>&1; then
        echo "✅ 找到: $pkg"
    else
        missing_packages+=("$pkg")
        echo "❌ 未找到: $pkg"
    fi
done

if [ ${#missing_packages[@]} -gt 0 ]; then
    echo "❌ 错误: 缺少必需的内核包: ${missing_packages[*]}"
    echo "💡 请确保在工作流中正确下载了内核包"
    exit 1
fi

echo "✅ 所有必需的内核包已就绪"

# Clean up old rootfs
echo "🧹 清理旧的rootfs目录..."
if [ -d "rootdir" ]; then
    rm -rf rootdir
    echo "✅ 旧目录已清理"
fi

# Create rootfs directory
echo "📁 创建rootfs目录结构..."
mkdir -p rootdir
echo "✅ 目录结构创建完成"

# Bootstrap the rootfs
echo "🌱 开始引导系统 (debootstrap)..."
echo "📥 下载: $distro_type $distro_version"
if sudo debootstrap --arch=arm64 --components=main,contrib,non-free,non-free-firmware "$distro_version" rootdir "http://deb.debian.org/debian/"; then
    echo "✅ 系统引导完成"
else
    echo "❌ debootstrap 失败"
    exit 1
fi

# Mount proc, sys, dev
echo "🔗 挂载虚拟文件系统..."
sudo mount -t proc proc rootdir/proc
sudo mount -t sysfs sysfs rootdir/sys
sudo mount -o bind /dev rootdir/dev
sudo mount -o bind /dev/pts rootdir/dev/pts
echo "✅ 虚拟文件系统挂载完成"

# Install base packages
echo "📦 安装基础系统包..."
if chroot rootdir apt update; then
    echo "✅ 软件包列表更新完成"
else
    echo "❌ 软件包列表更新失败"
    exit 1
fi

echo "🔧 安装系统工具包..."
if chroot rootdir apt install -y systemd systemd-sysv init udev dbus; then
    echo "✅ 系统工具包安装完成"
else
    echo "❌ 系统工具包安装失败"
    exit 1
fi

# Install device-specific packages
echo "📱 安装设备特定包..."
if chroot rootdir apt install -y linux-image-arm64 linux-headers-arm64; then
    echo "✅ 设备包安装完成"
else
    echo "❌ 设备包安装失败"
    exit 1
fi

# Set root password
echo "🔐 设置root密码..."
echo -e "1234\n1234" | sudo chroot rootdir passwd root > /dev/null 2>&1
echo "✅ Root密码已设置为: 1234"

# Install desktop environment for desktop variants
if [ "$distro_variant" = "desktop" ]; then
    echo "🖥️ 安装桌面环境..."
    chroot rootdir apt update
    if [ "$distro_type" = "debian" ]; then
        echo "🎨 安装Xfce桌面环境..."
        if chroot rootdir apt install -y xfce4 xfce4-goodies; then
            echo "✅ Xfce桌面环境安装完成 (Debian)"
        else
            echo "❌ Xfce桌面环境安装失败"
            exit 1
        fi
    elif [ "$distro_type" = "ubuntu" ]; then
        echo "🎨 安装Ubuntu桌面环境..."
        if chroot rootdir apt install -y ubuntu-desktop-minimal; then
            echo "✅ Ubuntu桌面环境安装完成"
        else
            echo "❌ Ubuntu桌面环境安装失败"
            exit 1
        fi
    fi
fi

# Unmount filesystems
echo "🔓 卸载虚拟文件系统..."
sudo umount -lf rootdir/proc > /dev/null 2>&1 || true
sudo umount -lf rootdir/sys > /dev/null 2>&1 || true
sudo umount -lf rootdir/dev/pts > /dev/null 2>&1 || true
sudo umount -lf rootdir/dev > /dev/null 2>&1 || true
echo "✅ 虚拟文件系统卸载完成"

# Create 7z archive
echo "🗜️ 创建压缩包..."
output_file="raphael-${distro_type}-${distro_variant}-$2.7z"
if sudo 7z a -t7z -m0=lzma -mx=9 -mfb=64 -md=32m -ms=on "${output_file}" rootdir/; then
    echo "✅ 压缩包创建成功: ${output_file}"
    echo "📊 文件大小: $(du -h "${output_file}" | cut -f1)"
else
    echo "❌ 压缩包创建失败"
    exit 1
fi

echo "🎉 $distro_type-$distro_variant 构建完成！"