#!/bin/bash

set -e

# 导入统一日志库
. ./logging.sh

# 检查参数
check_arguments 2 "$0 <发行版类型-变体> <内核版本>" "$0 debian-server 6.18"

# 检查root权限
check_root

log_header "开始构建 $1 发行版，内核版本 $2"
log_info "参数检查: distro=$1, kernel=$2"

# 解析发行版信息
distro_type=$(echo "$1" | cut -d'-' -f1)
distro_variant=$(echo "$1" | cut -d'-' -f2)

# 根据发行版类型设置默认版本
if [ "$distro_type" = "debian" ]; then
    distro_version="trixie"  # Debian 13 (trixie)
elif [ "$distro_type" = "ubuntu" ]; then
    distro_version="noble"   # Ubuntu 24.04 (noble)
else
    log_error "错误: 不支持的发行版类型: $distro_type"
    exit 1
fi

log_info "解析发行版信息:"
log_info "  类型: $distro_type"
log_info "  变体: $distro_variant"
log_info "  版本: $distro_version (默认)"
log_info "  内核: $2"

# 检查必需的内核包
log_package "检查内核包文件..."
# 使用兼容的shell语法检查包文件
found_packages=0
missing_packages=""

# 检查每个包文件（使用不带版本号的文件名）
if ls linux-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    log_success "找到: linux-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="linux-xiaomi-raphael*.deb $missing_packages"
    log_error "未找到: linux-xiaomi-raphael*.deb"
fi

if ls firmware-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    log_success "找到: firmware-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="firmware-xiaomi-raphael*.deb $missing_packages"
    log_error "未找到: firmware-xiaomi-raphael*.deb"
fi

if ls alsa-xiaomi-raphael*.deb 1> /dev/null 2>&1; then
    log_success "找到: alsa-xiaomi-raphael*.deb"
    found_packages=$((found_packages + 1))
else
    missing_packages="alsa-xiaomi-raphael*.deb $missing_packages"
    log_error "未找到: alsa-xiaomi-raphael*.deb"
fi

if [ $found_packages -lt 3 ]; then
    log_error "错误: 缺少必需的内核包: $missing_packages"
    log_info "请确保在工作流中正确下载了内核包"
    log_file "当前目录文件列表:"
    ls -la *.deb 2>/dev/null || log_info "  没有找到 .deb 文件"
    exit 1
fi

log_success "所有必需的内核包已就绪 ($found_packages/3)"

# 清理旧的rootfs和镜像文件
log_file "清理旧的rootfs和镜像文件..."
if [ -d "rootdir" ]; then
    umount rootdir/sys 2>/dev/null || true
    umount rootdir/proc 2>/dev/null || true
    umount rootdir/dev/pts 2>/dev/null || true
    umount rootdir/dev 2>/dev/null || true
    umount rootdir 2>/dev/null || true
    rm -rf rootdir
    log_success "旧目录已清理"
fi

if [ -f "rootfs.img" ]; then
    rm -f rootfs.img
    log_success "旧镜像文件已清理"
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

echo "📦 安装系统工具包..."
if chroot rootdir apt install -qq -y systemd systemd-sysv init udev dbus alsa-ucm-conf; then
    echo "✅ 系统工具包安装完成"
else
    echo "❌ 系统工具包安装失败"
    exit 1
fi


# 设置root密码 (所有环境通用)
echo "🔑 设置root密码..."
echo "root:123456" | chroot rootdir chpasswd
echo "✅ root密码设置完成 (密码: 123456)"

# 添加重要安全提示
echo "⚠️  ⚠️  ⚠️  重要安全提示 ⚠️  ⚠️  ⚠️"
echo "root密码: 123456"
echo "首次登录后请立即修改密码！"
echo "⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️  ⚠️"

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
echo "PARTLABEL=linux / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=esp /boot/efi vfat umask=0077 0 1" | tee rootdir/etc/fstab



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
        echo "🎨 安装Xfce桌面环境..."
        # 安装完整的Xfce组件，包括会话管理、面板、窗口管理器等
        if chroot rootdir apt install -qq -y xfce4 xfce4-goodies xfce4-session xfce4-panel xfwm4 xfdesktop4 lightdm xorg xserver-xorg-input-all xserver-xorg-video-all libgl1 libgl1-mesa-dri polkit dbus-x11; then
            echo "✅ Xfce桌面环境和LightDM显示管理器安装完成 (Debian)"
            
            # 配置LightDM默认会话为Xfce
            echo "🔧 配置LightDM默认会话为Xfce..."
            mkdir -p rootdir/etc/lightdm
            cat > rootdir/etc/lightdm/lightdm.conf << EOF
[Seat:*]
user-session=xfce
EOF
            echo "✅ LightDM默认会话配置完成"
        else
            echo "❌ Xfce桌面环境安装失败"
            exit 1
        fi
    elif [ "$distro_type" = "ubuntu" ]; then
        echo "🎨 安装Ubuntu桌面环境..."
        if chroot rootdir apt install -qq -y ubuntu-desktop; then
            echo "✅ Ubuntu桌面环境安装完成"
            # 创建GDM目录（仅Ubuntu使用GDM）
            echo "🔧 配置GDM显示管理器..."
            mkdir -p rootdir/var/lib/gdm
            touch rootdir/var/lib/gdm/run-initial-setup
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
        if chroot rootdir systemctl enable lightdm.service; then
            echo "✅ LightDM显示管理器已启用"
            # 添加调试信息：检查LightDM服务状态
            if chroot rootdir systemctl is-enabled lightdm.service >/dev/null; then
                echo "🔍 LightDM服务已启用"
            else
                echo "🔍 LightDM服务未启用"
            fi
        else
            echo "❌ LightDM显示管理器启用失败"
            exit 1
        fi
    elif [ "$distro_type" = "ubuntu" ]; then
        # 明确启用GDM3服务，确保服务正常运行
        if chroot rootdir systemctl enable gdm3.service; then
            echo "✅ GDM3显示管理器已启用"
            # 添加调试信息：检查GDM3服务状态
            if chroot rootdir systemctl is-enabled gdm3.service >/dev/null; then
                echo "🔍 GDM3服务已启用"
            else
                echo "🔍 GDM3服务未启用"
            fi
        else
            echo "❌ GDM3显示管理器启用失败"
            exit 1
        fi
    fi
    
    # 安装必要的图形驱动和组件
    echo "🔧 安装必要的图形组件..."
    if chroot rootdir apt install -qq -y xserver-xorg x11-xserver-utils; then
        echo "✅ 图形组件安装完成"
        # 添加调试信息：检查关键图形组件是否安装
        if chroot rootdir dpkg -l | grep -q xserver-xorg; then
            echo "🔍 xserver-xorg已安装"
        else
            echo "🔍 xserver-xorg未安装"
        fi
    else
        echo "❌ 图形组件安装失败"
        exit 1
    fi
    
    # 创建普通用户（用于桌面登录）
    echo "👤 创建普通用户..."
    if ! chroot rootdir id -u user >/dev/null 2>&1; then
        chroot rootdir useradd -m -s /bin/bash user
        echo "user:user" | chroot rootdir chpasswd
        # 为用户添加sudo权限
        chroot rootdir usermod -aG sudo user
        echo "✅ 普通用户 'user' 创建完成（密码: user）"
        
        # 配置用户默认会话为Xfce
        mkdir -p rootdir/home/user/.config
        cat > rootdir/home/user/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="FailsafeSessionName" type="string" value="xfce"/>
    <property name="SessionName" type="string" value="Default"/>
  </property>
</channel>
EOF
        # 设置用户权限
        chroot rootdir chown -R user:user /home/user/.config
        echo "✅ 用户Xfce会话配置完成"
    else
        echo "⚠️ 用户 'user' 已存在"
    fi
    
    # 添加完整的图形系统状态检查
    echo "🔍 图形系统状态检查..."
    
    # 检查关键图形服务状态
    if [ "$distro_type" = "debian" ]; then
        echo "📋 Debian图形服务状态检查:"
        # 检查LightDM服务状态
        if chroot rootdir systemctl is-enabled lightdm.service >/dev/null; then
            echo "   ✅ LightDM服务已启用"
        else
            echo "   ❌ LightDM服务未启用"
        fi
        # 检查DBus服务状态
        if chroot rootdir systemctl is-enabled dbus.service >/dev/null; then
            echo "   ✅ DBus服务已启用"
        else
            echo "   ❌ DBus服务未启用"
        fi
    elif [ "$distro_type" = "ubuntu" ]; then
        echo "📋 Ubuntu图形服务状态检查:"
        # 检查GDM3服务状态
        if chroot rootdir systemctl is-enabled gdm3.service >/dev/null; then
            echo "   ✅ GDM3服务已启用"
        else
            echo "   ❌ GDM3服务未启用"
        fi
        # 检查DBus服务状态
        if chroot rootdir systemctl is-enabled dbus.service >/dev/null; then
            echo "   ✅ DBus服务已启用"
        else
            echo "   ❌ DBus服务未启用"
        fi
    fi
    
    # 检查Xfce会话配置
    echo "📋 Xfce会话配置检查:"
    if chroot rootdir dpkg -l | grep -q xfce4-session; then
        echo "   ✅ Xfce会话管理器已安装"
    else
        echo "   ❌ Xfce会话管理器未安装"
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
output_file="raphael-${distro_type}-${distro_variant}-$2.7z"
if 7z a "${output_file}" rootfs.img; then
    echo "✅ 压缩包创建成功: ${output_file}"
    echo "📊 文件大小: $(du -h "${output_file}" | cut -f1)"
else
    echo "❌ 压缩包创建失败"
    exit 1
fi

echo "🎉 $distro_type-$distro_variant IMG镜像构建完成！"
