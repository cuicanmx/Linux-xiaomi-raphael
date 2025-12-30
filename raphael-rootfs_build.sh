set -e

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

# 根据变体设置镜像大小
if [ "$distro_variant" = "server" ]; then
    IMAGE_SIZE="2G"
    echo "  镜像大小: 2G (Server版)"
elif [ "$distro_variant" = "desktop" ]; then
    IMAGE_SIZE="8G"
    echo "  镜像大小: 8G (Desktop版)"
else
    echo "错误: 不支持的变体类型: $distro_variant"
    echo "支持的变体: server, desktop"
    exit 1
fi

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
	bash-completion chrony initramfs-tools
    # 基础工具
    sudo vim wget curl openssh-server network-manager alsa-ucm-conf
)

echo "执行命令: chroot rootdir apt install -qq -y ${base_packages[*]}"
if chroot rootdir apt install -qq -y "${base_packages[@]}"; then
    echo "✅ 核心基础包安装完成"
else
    echo "❌ 核心基础包安装失败"
    exit 1
fi

# 安装Xiaomi设备特定包
echo "📱 安装Xiaomi设备特定包..."
device_packages=(
    rmtfs
    protection-domain-mapper
    tqftpserv
)

echo "执行命令: chroot rootdir apt install -qq -y ${device_packages[*]}"
if chroot rootdir apt install -qq -y "${device_packages[@]}"; then
    echo "✅ Xiaomi设备特定包安装完成"
else
    echo "❌ Xiaomi设备特定包安装失败"
    exit 1
fi

# 修复pd-mapper服务
echo "🔧 修复pd-mapper服务配置..."
if [ -f "rootdir/lib/systemd/system/pd-mapper.service" ]; then
    sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service
    echo "✅ pd-mapper服务配置已修复"
else
    echo "⚠️  未找到pd-mapper.service文件"
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

# 生成 initramfs
chroot rootdir update-initramfs -c -k all

# 生成 boot
mkdir -p boot_tmp
wget https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img
mount -o loop xiaomi-k20pro-boot.img boot_tmp

cp -r rootdir/boot/dtbs/qcom boot_tmp/dtbs/
cp rootdir/boot/config-* boot_tmp/
cp rootdir/boot/initrd.img-* boot_tmp/initramfs
cp rootdir/boot/vmlinuz-* boot_tmp/linux.efi

umount boot_tmp
rm -d boot_tmp

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
    
    if [ "$distro_type" = "debian" ]; then
        echo "🎨 安装GNOME桌面环境..."
        if chroot rootdir apt install -qq -y task-gnome-desktop; then
            echo "✅ GNOME桌面环境安装完成 (Debian)"
            
            # ============ 创建默认用户 ============
            echo "👤 为Debian桌面创建默认用户..."
            # 设置root密码
            echo "root:root" | chroot rootdir chpasswd
            
            # 创建普通用户
            chroot rootdir useradd -m -G sudo -s /bin/bash user
            echo "user:1234" | chroot rootdir chpasswd
            
            # 设置自动登录
            echo "[daemon]
AutomaticLoginEnable=true
AutomaticLogin=user" > rootdir/etc/gdm3/daemon.conf
            
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
			
            # ============ 创建默认用户 ============
            echo "👤 为Ubuntu桌面创建默认用户..."
            # 设置root密码
            echo "root:root" | chroot rootdir chpasswd
            
            # 创建普通用户
            chroot rootdir useradd -m -G sudo -s /bin/bash user
            echo "user:1234" | chroot rootdir chpasswd
            
            # 设置自动登录
            echo "[daemon]
AutomaticLoginEnable=true
AutomaticLogin=user" > rootdir/etc/gdm3/daemon.conf
			
            mkdir -p rootdir/var/lib/gdm
            touch rootdir/var/lib/gdm/run-initial-setup
            echo "✅ GDM初始配置完成"
        else
            echo "❌ Ubuntu桌面环境安装失败"
            exit 1
        fi
    fi
fi

rm rootdir/lib/firmware/reg*

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

# Create 7z archive with maximum compression
echo "🗜️ 创建压缩包 (最大压缩)..."
output_file="raphael-${1}-kernel-$2.7z"
echo "输出文件: $output_file"
if 7z a -mx=9 -mfb=258 -md=256k -ms=on "${output_file}" rootfs.img; then
    echo "✅ 压缩包创建成功: ${output_file}"
    echo "📊 文件大小: $(du -h "${output_file}" | cut -f1)"
else
    echo "❌ 压缩包创建失败"
    exit 1
fi

echo "🎉 $distro_type-$distro_variant IMG镜像构建完成！"