#!/bin/bash

set -e

# 设置脚本参数数量
SCRIPT_ARG_COUNT=$#

# 检查参数
if [ $SCRIPT_ARG_COUNT -lt 2 ]; then
    echo "错误: 参数数量不足，期望 2 个参数"
    echo "用法: $0 <发行版类型-变体> <内核版本>"
    echo "示例: $0 debian-server 6.18"
    exit 1
fi

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要root权限运行此脚本"
    exit 1
fi

echo ""
echo "=========================================="
echo "开始构建 $1 发行版，内核版本 $2"
echo "=========================================="
echo ""
echo "参数检查: distro=$1, kernel=$2"

# 解析发行版信息
distro_type=$(echo "$1" | cut -d'-' -f1)
distro_variant=$(echo "$1" | cut -d'-' -f2)

# 根据发行版类型设置默认版本
if [ "$distro_type" = "debian" ]; then
    distro_version="trixie"  # Debian 13 (trixie)
elif [ "$distro_type" = "ubuntu" ]; then
    distro_version="noble"   # Ubuntu 24.04 (noble)
else
    echo "错误: 不支持的发行版类型: $distro_type"
    exit 1
fi

echo "解析发行版信息:"
echo "  类型: $distro_type"
echo "  变体: $distro_variant"
echo "  版本: $distro_version (默认)"
echo "  内核: $2"

# 检查必需的内核包
echo "检查内核包文件..."
# 使用兼容的shell语法检查包文件
found_packages=0
missing_packages=""

# 检查每个包文件（使用不带版本号的文件名）
if ls linux-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    echo "找到: linux-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="linux-xiaomi-raphael*.deb $missing_packages"
    echo "未找到: linux-xiaomi-raphael*.deb"
fi

if ls firmware-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    echo "找到: firmware-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="firmware-xiaomi-raphael*.deb $missing_packages"
    echo "未找到: firmware-xiaomi-raphael*.deb"
fi

if ls alsa-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    echo "找到: alsa-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="alsa-xiaomi-raphael*.deb $missing_packages"
    echo "未找到: alsa-xiaomi-raphael*.deb"
fi

if [ $found_packages -lt 3 ]; then
    echo "错误: 缺少必需的内核包: $missing_packages"
    echo "请确保在工作流中正确下载了内核包"
    echo "当前目录文件列表:"
    ls -la *.deb 2>/dev/null || echo "  没有找到 .deb 文件"
    exit 1
fi

echo "所有必需的内核包已就绪 ($found_packages/3)"

# 清理旧的rootfs和镜像文件
echo "清理旧的rootfs和镜像文件..."
if [ -d "rootdir" ]; then
    umount rootdir/sys 2>/dev/null || true
    umount rootdir/proc 2>/dev/null || true
    umount rootdir/dev/pts 2>/dev/null || true
    umount rootdir/dev 2>/dev/null || true
    umount rootdir 2>/dev/null || true
    rm -rf rootdir
    echo "旧目录已清理"
fi

if [ -f "rootfs.img" ]; then
    rm -f rootfs.img
    echo "旧镜像文件已清理"
fi

# Create and mount image file
echo "创建IMG镜像文件..."
truncate -s 6G rootfs.img
mkfs.ext4 rootfs.img
mkdir -p rootdir
mount -o loop rootfs.img rootdir
echo "6GB镜像文件创建并挂载完成"

# Bootstrap the rootfs
echo "开始引导系统 (debootstrap)..."
echo "下载: $distro_type $distro_version"

# Set mirror based on distribution type
if [ "$distro_type" = "debian" ]; then
    mirror="http://deb.debian.org/debian/"
elif [ "$distro_type" = "ubuntu" ]; then
    mirror="http://ports.ubuntu.com/ubuntu-ports/"
fi

echo "使用镜像源: $mirror"

if sudo debootstrap --arch=arm64 "$distro_version" rootdir "$mirror"; then
    echo "✅ 系统引导完成"
else
    echo "❌ debootstrap 失败"
    echo "💡 请检查网络连接和镜像源可用性"
    exit 1
fi

# Mount proc, sys, dev
echo "挂载虚拟文件系统..."
mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

echo "虚拟文件系统挂载完成"

# Install base packages
echo "📦 安装基础系统包..."
if chroot rootdir apt -qq update; then
    echo "✅ 软件包列表更新完成"
else
    echo "❌ 软件包列表更新失败"
    exit 1
fi

echo "📦 安装系统工具包..."
if chroot rootdir apt install -qq -y systemd systemd-sysv init udev dbus alsa-ucm-conf initramfs-tools wget u-boot-tools; then
    echo "✅ 系统工具包安装完成"
else
    echo "❌ 系统工具包安装失败"
    exit 1
fi


# 设置root密码 (仅服务器环境)
if [[ "$distro_variant" != *"desktop"* ]]; then
    echo "🔑 设置root密码..."
    echo "root:123456" | chroot rootdir chpasswd
    echo "✅ root密码设置完成 (密码: 123456)"

    # 添加重要安全提示
    echo "⚠️  ⚠️  ⚠️  重要安全提示 ⚠️  ⚠️  ⚠️"
    echo "root密码: 123456"
    echo "首次登录后请立即修改密码！"
    echo "⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️"
fi

# 配置SSH (仅服务器环境)
if [[ "$distro_variant" == *"desktop"* ]]; then
    echo "🎨 桌面环境检测: 跳过SSH配置"
else
    echo "🖥️  服务器环境检测: 开始配置SSH"
    
    # 安装SSH服务器
    echo "🔧 安装SSH服务器..."
    if chroot rootdir apt install -qq -y openssh-server; then
        echo "✅ SSH服务器安装完成"
    else
        echo "❌ SSH服务器安装失败"
        exit 1
    fi
    
    # 配置SSH允许root登录
    echo "🔓 配置SSH允许root登录..."
    echo "PermitRootLogin yes" >> rootdir/etc/ssh/sshd_config
    echo "PasswordAuthentication yes" >> rootdir/etc/ssh/sshd_config
    
    # 启用SSH服务
    chroot rootdir systemctl enable ssh
    
    echo "✅ SSH配置完成: root登录已启用"
fi

echo "🔄 更新系统..."
if chroot rootdir apt -qq upgrade -y; then
    echo "✅ 系统更新完成"
else
    echo "⚠️  系统更新部分失败，继续构建"
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

# 安装设备特定服务
echo "🔧 安装设备特定服务..."
if [ "$distro_type" = "debian" ]; then
    # Debian支持所有三个包
    chroot rootdir apt install -y rmtfs protection-domain-mapper tqftpserv
else
    # Ubuntu只支持protection-domain-mapper
    chroot rootdir apt install -y protection-domain-mapper
fi
sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service
echo "✅ 设备特定服务安装完成"

# 更新initramfs
echo "🔧 更新initramfs..."
chroot rootdir update-initramfs -c -k all
echo "✅ initramfs更新完成"

echo "✅ 所有设备特定包安装完成"

# 配置自动DHCP网络
echo "🌐 配置 systemd-networkd 自动DHCP..."
cat > rootdir/etc/systemd/network/20-eth0.network << EOF
[Match]
Name=eth0

[Network]
DHCP=yes
EOF
# 启用服务
chroot rootdir systemctl enable systemd-networkd
echo "✅ 自动DHCP网络配置完成。"

# Create fstab
echo "📋 创建文件系统表..."
echo "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077 0 1" | tee rootdir/etc/fstab



# Clean package cache
echo "🧹 清理软件包缓存..."
chroot rootdir apt -qq clean
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
        echo "🎨 安装GNOME桌面环境..."
        if chroot rootdir apt install -qq -y task-gnome-desktop; then
            echo "✅ GNOME桌面环境安装完成 (Debian)"
            mkdir -p rootdir/var/lib/gdm
            touch rootdir/var/lib/gdm/run-initial-setup
            echo "✅ GDM初始配置完成"
        else
            echo "❌ GNOME桌面环境安装失败"
            exit 1
        fi
    elif [ "$distro_type" = "ubuntu" ]; then
        echo "🎨 安装Ubuntu桌面环境..."
        if chroot rootdir apt install -qq -y ubuntu-desktop; then
            echo "✅ Ubuntu桌面环境安装完成"
            mkdir -p rootdir/var/lib/gdm
            touch rootdir/var/lib/gdm/run-initial-setup
            echo "✅ GDM初始配置完成"
        else
            echo "❌ Ubuntu桌面环境安装失败"
            exit 1
        fi
    fi
    
    # 配置系统默认启动图形界面
    echo "🔧 配置系统默认启动图形界面..."
    if chroot rootdir systemctl set-default graphical.target; then
        echo "✅ 已设置默认启动目标为 graphical.target"
        # 添加调试信息：检查当前默认目标
        current_target=$(chroot rootdir systemctl get-default)
        echo "🔍 当前默认启动目标: $current_target"
    else
        echo "❌ 设置默认启动目标失败"
        exit 1
    fi
    
    # 启用显示管理器服务
    if [ "$distro_type" = "debian" ]; then
        # GNOME使用GDM作为显示管理器，已由task-gnome-desktop自动配置
        echo "✅ GDM显示管理器已自动配置"
    fi
    # 安装ubuntu-desktop元包已包含所有必要的图形组件和服务配置
    
    # 创建普通用户（用于桌面登录）
    echo "👤 创建普通用户..."
    if ! chroot rootdir id -u user >/dev/null 2>&1; then
        chroot rootdir useradd -m -s /bin/bash user
        echo "user:user" | chroot rootdir chpasswd
        # 为用户添加sudo权限
        chroot rootdir usermod -aG sudo user
        echo "✅ 普通用户 'user' 创建完成（密码: user）"
        
        # Debian和Ubuntu现在都使用GNOME桌面环境
        mkdir -p rootdir/home/user/.config
        echo "✅ 用户会话配置完成（GNOME默认）"
        # 设置用户权限
        chroot rootdir chown -R user:user /home/user/.config
    else
        echo "⚠️ 用户 'user' 已存在"
    fi
    
    # 添加完整的图形系统状态检查
    echo "🔍 图形系统状态检查..."
    
    # 检查关键图形服务状态 - 两个发行版现在都使用GDM
    echo "📋 图形服务状态检查:"
    # 检查GDM/GDM3服务状态
    if chroot rootdir systemctl is-enabled gdm.service || chroot rootdir systemctl is-enabled gdm3.service; then
        echo "   ✅ GDM服务已启用"
    else
        echo "   ❌ GDM服务未启用"
    fi
    # 检查DBus服务状态
    if chroot rootdir systemctl is-enabled dbus.service >/dev/null; then
        echo "   ✅ DBus服务已启用"
    else
        echo "   ❌ DBus服务未启用"
    fi
    
    # 检查GNOME会话配置
    echo "📋 GNOME会话配置检查:"
    if chroot rootdir dpkg -l | grep -q gnome-session; then
        echo "   ✅ GNOME会话管理器已安装"
    else
        echo "   ❌ GNOME会话管理器未安装"
    fi
    
    # 检查默认启动目标
    echo "📋 系统启动目标检查:"
    current_target=$(chroot rootdir systemctl get-default)
    echo "   当前默认启动目标: $current_target"
    if [ "$current_target" = "graphical.target" ]; then
        echo "   ✅ 系统将以图形模式启动"
    else
        echo "   ❌ 系统将不以图形模式启动"
    fi
    
    echo "✅ 桌面环境和图形系统配置完成"
fi

# 执行内核更新脚本确保正常启动
echo "🔧 执行内核更新脚本..."
chroot rootdir bash -c "$(curl -fsSL https://raw.githubusercontent.com/GengWei1997/kernel-deb/refs/heads/main/Update-kernel.sh)"
echo "✅ 内核更新脚本执行完成"

# Unmount filesystems
echo "🔓 卸载虚拟文件系统..."
# 先卸载rootdir内部的虚拟文件系统
umount -t sysfs -f rootdir/sys 2>/dev/null || echo "⚠️  sysfs未挂载或卸载失败"
umount -t proc -f rootdir/proc 2>/dev/null || echo "⚠️  proc未挂载或卸载失败"
umount -t devpts -f rootdir/dev/pts 2>/dev/null || echo "⚠️  devpts未挂载或卸载失败"
umount -l rootdir/dev 2>/dev/null || echo "⚠️  /dev未挂载或卸载失败"

# 然后卸载rootdir本身（rootfs.img挂载点）
echo "🔓 卸载rootfs.img..."
umount -f rootdir 2>/dev/null || echo "⚠️  rootfs.img未挂载或卸载失败"

# 最后清理目录
echo "🧹 清理rootdir目录..."
rm -rf rootdir
echo "✅ 虚拟文件系统卸载和目录清理完成"

# 临时目录已经在卸载步骤中清理完成
echo "✅ 所有临时目录清理完成"
echo "🔧 调整文件系统UUID..."
tune2fs -U ee8d3593-59b1-480e-a3b6-4fefb17ee7d8 rootfs.img
echo "✅ 文件系统UUID调整完成"
echo "检查目录下文件..."
ls 
# Create 7z archive
echo "🗜️ 创建压缩包..."
output_file="raphael-${distro_type}-${distro_variant}-kernel-$2.7z"
if 7z a "${output_file}" rootfs.img; then
    echo "✅ 压缩包创建成功: ${output_file}"
    echo "📊 文件大小: $(du -h "${output_file}" | cut -f1)"
else
    echo "❌ 压缩包创建失败"
    exit 1
fi

echo "🎉 $distro_type-$distro_variant IMG镜像构建完成！"