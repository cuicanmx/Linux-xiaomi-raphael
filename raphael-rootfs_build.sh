set -e

# 配置变量
IMAGE_SIZE="6G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

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

# 确保使用bash运行脚本
if [ -z "$BASH_VERSION" ]; then
    echo "❌ 错误: 请使用bash运行此脚本"
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

# 检查每个包文件（使用通配符匹配）
for pkg in linux-xiaomi-raphael firmware-xiaomi-raphael alsa-xiaomi-raphael; do
    if ls ${pkg}*.deb 1> /dev/null 2>&1; then
        echo "找到: ${pkg}*.deb"
        found_packages=$((found_packages + 1))
    else
        missing_packages="${pkg}*.deb $missing_packages"
        echo "未找到: ${pkg}*.deb"
    fi
done

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
    # 尝试优雅卸载
    for mountpoint in sys proc dev/pts dev; do
        if mountpoint -q "rootdir/$mountpoint"; then
            umount "rootdir/$mountpoint" || echo "警告: 无法卸载 rootdir/$mountpoint"
        fi
    done
    if mountpoint -q "rootdir"; then
        umount "rootdir" || echo "警告: 无法卸载 rootdir"
    fi
    rm -rf rootdir
    echo "旧目录已清理"
fi

if [ -f "rootfs.img" ]; then
    rm -f rootfs.img
    echo "旧镜像文件已清理"
fi

# Create and mount image file
echo "📁 创建IMG镜像文件..."
truncate -s $IMAGE_SIZE rootfs.img
mkfs.ext4 rootfs.img
mkdir -p rootdir
mount -o loop rootfs.img rootdir
echo "✅ 6GB镜像文件创建并挂载完成"

# Bootstrap the rootfs
echo "🌱 开始引导系统 (debootstrap)..."
echo "📥 下载: $distro_type $distro_version"
echo "🔗 使用镜像源: $mirror"

# Set mirror based on distribution type
 if [ "$distro_type" = "debian" ]; then
     mirror="http://deb.debian.org/debian/"
 elif [ "$distro_type" = "ubuntu" ]; then
     mirror="http://ports.ubuntu.com/ubuntu-ports/"
 fi

echo "🔗 使用镜像源: $mirror"

echo "执行命令: sudo debootstrap --arch=arm64 $distro_version rootdir $mirror"
if sudo debootstrap --arch=arm64 -–variant "$distro_version" rootdir "$mirror"; then
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

# Update package list
echo "🔄 更新软件包列表..."
if chroot rootdir apt update; then
    echo "✅ 软件包列表更新完成"
else
    echo "❌ 软件包列表更新失败"
    exit 1
fi

# ======================== 关键修改1：补充服务器版最小包 + WiFi组件 ========================
echo "📦 安装核心基础包"
base_packages=(
    # 系统核心
    systemd udev dbus bash-completion
    # 网络基础（强制DHCP+WiFi）
    systemd-resolved wpasupplicant iw iproute2 sudo
    # SSH依赖
    openssh-server openssh-client 
    # 基础工具
    sudo vim wget curl iputils-ping traceroute
    # WiFi配置工具
    network-manager wireless-regdb 
    # 音频/硬件兼容
    alsa-ucm-conf alsa-utils 
)

echo "执行命令: chroot rootdir apt install -qq -y ${base_packages[*]}"
if chroot rootdir apt install -qq -y "${base_packages[@]}"; then
    echo "✅ 核心基础包安装完成"
else
    echo "❌ 核心基础包安装失败"
    exit 1
fi
# ======================================================================================



# 配置SSH (仅服务器环境)
if [[ "$distro_variant" == *"desktop"* ]]; then
    echo "🎨 桌面环境检测: 跳过SSH配置"
else
    echo "🖥️  服务器环境检测: 开始配置SSH"
    
    # ======================== 关键修改2：优化SSH配置 ========================
    echo "🔧 配置SSH服务..."
    # 备份原配置
    chroot rootdir cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    # 清空原有配置，写入最小化可靠配置
    cat > rootdir/etc/ssh/sshd_config << EOF
# 基础配置
Port 22
ListenAddress 0.0.0.0
ListenAddress ::
Protocol 2

# 认证配置
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
PubkeyAuthentication yes

# 安全配置
PermitEmptyPasswords no
MaxAuthTries 6
MaxSessions 10

# 服务配置
UsePAM yes
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
    
    # 修复SSH目录权限
    chroot rootdir chmod 700 /var/run/sshd
    chroot rootdir chmod 755 /etc/ssh
    
    # 启用并设置SSH开机自启
    chroot rootdir systemctl enable ssh
    
    echo "✅ SSH配置完成: 监听所有IP，允许root密码登录"
    # ======================================================================
fi

# Install device-specific packages
echo "📱 安装设备特定包..."
echo "📦 复制内核包到 chroot 环境..."

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

# ======================== 关键修改3：全网卡强制DHCP配置 ========================
echo "🌐 配置所有网络接口强制DHCP..."

# 配置1：匹配所有有线/无线接口（通配符）
cat > rootdir/etc/systemd/network/00-all-interfaces.network << EOF
[Match]
Name=*  # 匹配所有网卡（eth*, wlan*, en*, wl*, 等）

[Network]
DHCP=yes  # 强制DHCPv4
DHCPv6=yes  # 可选：启用DHCPv6
LLMNR=yes
MulticastDNS=yes

[DHCP]
UseDomains=yes
EOF

# systemd-networkd和resolved已通过软件包自动启用

# resolv.conf符号链接已由systemd-resolved自动创建

echo "✅ 全网卡强制DHCP配置完成：所有接口自动获取IP，DNS动态管理"
# ==============================================================================

# Create fstab
echo "📋 创建文件系统表..."
echo "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077,nofail 0 1" | tee rootdir/etc/fstab
# Clean package cache
echo "🧹 清理软件包缓存..."
chroot rootdir apt -qq clean

# Network and system configuration
echo "🔧 配置系统基础设置..."
echo "xiaomi-raphael" | tee rootdir/etc/hostname
echo "127.0.0.1 localhost
127.0.1.1 xiaomi-raphael
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters" | tee rootdir/etc/hosts
echo "✅ 主机名和hosts配置完成"

# Install desktop environment for desktop variants
if [ "$distro_variant" = "desktop" ]; then
    echo "🖥️ 安装桌面环境..."
    # 已在之前执行过apt update，无需重复执行
    
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
        echo "执行命令: chroot rootdir apt install -qq -y ubuntu-desktop"
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
        echo "✅ GDM显示管理器已自动配置"
    fi
    
    
    # 图形系统状态检查
    echo "🔍 图形系统状态检查..."
    echo "📋 图形服务状态检查:"
    if chroot rootdir systemctl is-enabled gdm.service || chroot rootdir systemctl is-enabled gdm3.service; then
        echo "   ✅ GDM服务已启用"
    else
        echo "   ❌ GDM服务未启用"
    fi
    if chroot rootdir systemctl is-enabled dbus.service >/dev/null; then
        echo "   ✅ DBus服务已启用"
    else
        echo "   ❌ DBus服务未启用"
    fi
    
    echo "📋 GNOME会话配置检查:"
    if chroot rootdir dpkg -l | grep -q gnome-session; then
        echo "   ✅ GNOME会话管理器已安装"
    else
        echo "   ❌ GNOME会话管理器未安装"
    fi
    
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
# 优雅卸载，避免强制卸载
for mountpoint in sys proc dev/pts dev; do
    if mountpoint -q "rootdir/$mountpoint"; then
        umount "rootdir/$mountpoint" || echo "⚠️  无法卸载 rootdir/$mountpoint"
    fi
done

echo "🔓 卸载rootfs.img..."
if mountpoint -q "rootdir"; then
    umount "rootdir" || echo "⚠️  无法卸载 rootdir"
fi

echo "🧹 清理rootdir目录..."
rm -rf rootdir
echo "✅ 虚拟文件系统卸载和目录清理完成"

echo "🔧 调整文件系统UUID..."
tune2fs -U $FILESYSTEM_UUID rootfs.img
echo "✅ 文件系统UUID调整完成"

echo "检查目录下文件..."
ls 

# Create 7z archive
echo "🗜️ 创建压缩包..."
output_file="raphael-${1}-kernel-$2.7z"
echo "输出文件: $output_file"
if 7z a "${output_file}" rootfs.img; then
    echo "✅ 压缩包创建成功: ${output_file}"
    echo "📊 文件大小: $(du -h "${output_file}" | cut -f1)"
else
    echo "❌ 压缩包创建失败"
    exit 1
fi

echo "🎉 $distro_type-$distro_variant IMG镜像构建完成！"