set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置变量
IMAGE_SIZE="6G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

# 设置脚本参数数量
SCRIPT_ARG_COUNT=$#

# 检查参数
if [ $SCRIPT_ARG_COUNT -lt 2 ]; then
    echo -e "${RED}错误: 参数数量不足，期望 2-3 个参数${NC}"
    echo -e "${YELLOW}用法: $0 <发行版类型-变体> <内核版本> [use_china_mirror]${NC}"
    echo -e "${YELLOW}示例: $0 debian-server 6.18 true${NC}"
    exit 1
fi

# 处理可选参数
USE_CHINA_MIRROR="false"
if [ $SCRIPT_ARG_COUNT -ge 3 ]; then
    USE_CHINA_MIRROR="$3"
fi

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 需要root权限运行此脚本${NC}"
    exit 1
fi

# 确保使用bash运行脚本
if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}❌ 错误: 请使用bash运行此脚本${NC}"
    exit 1
fi

echo -e "${BLUE}"
echo "=========================================="
echo "开始构建 $1 发行版，内核版本 $2"
echo "=========================================="
echo -e "${NC}"
echo -e "${CYAN}参数检查: distro=$1, kernel=$2${NC}"

# 解析发行版信息
distro_type=$(echo "$1" | cut -d'-' -f1)
distro_variant=$(echo "$1" | cut -d'-' -f2)

# 根据发行版类型设置默认版本
if [ "$distro_type" = "debian" ]; then
    distro_version="trixie"  # Debian 13 (trixie)
else
    echo "错误: 不支持的发行版类型: $distro_type"
    exit 1
fi

echo -e "${CYAN}解析发行版信息:${NC}"
echo -e "  ${GREEN}类型:${NC} $distro_type"
echo -e "  ${GREEN}变体:${NC} $distro_variant"
echo -e "  ${GREEN}版本:${NC} $distro_version (默认)"
echo -e "  ${GREEN}内核:${NC} $2"

# 检查必需的内核包
echo -e "${CYAN}检查内核包文件...${NC}"
# 使用兼容的shell语法检查包文件
found_packages=0
missing_packages=""

# 检查每个包文件（使用通配符匹配）
for pkg in linux-xiaomi-raphael firmware-xiaomi-raphael alsa-xiaomi-raphael; do
    if ls ${pkg}*.deb 1> /dev/null 2>&1; then
        echo -e "  ${GREEN}找到:${NC} ${pkg}*.deb"
        found_packages=$((found_packages + 1))
    else
        missing_packages="${pkg}*.deb $missing_packages"
        echo -e "  ${RED}未找到:${NC} ${pkg}*.deb"
    fi
done

if [ $found_packages -lt 3 ]; then
    echo -e "${RED}错误: 缺少必需的内核包: $missing_packages${NC}"
    echo -e "${YELLOW}请确保在工作流中正确下载了内核包${NC}"
    echo -e "${YELLOW}当前目录文件列表:${NC}"
    ls -la *.deb 2>/dev/null || echo -e "  ${RED}没有找到 .deb 文件${NC}"
    exit 1
fi

echo -e "${GREEN}所有必需的内核包已就绪 ($found_packages/3)${NC}"

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
    systemd udev dbus bash-completion net-tools
    # 网络基础（强制DHCP+WiFi）
    systemd-resolved wpasupplicant iw iproute2 sudo
    # SSH依赖
    openssh-server openssh-client ntpsec-ntpdate
    # 基础工具
    vim wget curl iputils-ping
    # WiFi配置工具
    network-manager wireless-regdb 
    # 音频/硬件兼容
    alsa-ucm-conf alsa-utils initramfs-tools u-boot-tools
)

echo "执行命令: chroot rootdir apt install -qq -y ${base_packages[*]}"
if chroot rootdir apt install -qq -y "${base_packages[@]}"; then
    echo "✅ 核心基础包安装完成"
else
    echo "❌ 核心基础包安装失败"
    exit 1
fi
# ======================================================================================

# 使用passwd命令修改root密码为1234
echo "设置Root密码..."
# Debian构建使用--stdin参数
if chroot rootdir bash -c "echo '1234' | passwd --stdin root"; then
    echo "✅ Root密码设置完成: root/1234"
else
    # 如果--stdin参数不可用，尝试另一种方法
    echo "⚠️  passwd --stdin不可用，尝试替代方法..."
    chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"
    if [ $? -eq 0 ]; then
        echo "✅ Root密码设置完成: root/1234"
    else
        echo "❌ Root密码设置失败"
        exit 1
    fi
fi

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
    # 配置SSH权限
    echo "PermitRootLogin yes" >> rootdir/etc/ssh/sshd_config
    echo "PubkeyAuthentication yes" >> rootdir/etc/ssh/sshd_config
    echo "PasswordAuthentication yes" >> rootdir/etc/ssh/sshd_config
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


# 配置网络
# ======================== 关键修改3：全网卡强制DHCP配置 ========================
echo "🌐 配置所有网络接口强制DHCP..."
mkdir -p rootdir/etc/systemd/network/
cat > rootdir/etc/systemd/network/10-autodhcp.network << EOF
[Match]
# 匹配所有可能的网卡命名模式
Name=eth* en* wl* wlp* wlan* eno* ens* enp* enx* enP*

[Network]
DHCP=yes
LLDP=yes
EmitLLDP=nearest-bridge
IPv6AcceptRA=yes

[DHCP]
UseMTU=true
UseDNS=true
UseHostname=false
EOF
# 4. 禁用传统的network.service（如果存在）
chroot rootdir systemctl disable networking.service 2>/dev/null || true

# 5. 启用systemd-networkd
chroot rootdir systemctl enable systemd-networkd
chroot rootdir systemctl enable systemd-resolved

echo "✅ 全网卡强制DHCP配置完成：所有接口自动获取IP，DNS动态管理"
# ==============================================================================
chroot rootdir update-initramfs -c -k all

# Generated boot - 仅在构建debian-server时执行
if [ "$distro_type" = "debian" ] && [ "$distro_variant" = "server" ]; then
    mkdir -p boot_tmp
    wget https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img
    mount -o loop xiaomi-k20pro-boot.img boot_tmp

    cp -r rootdir/boot/dtbs/qcom boot_tmp/dtbs/
    cp rootdir/boot/config-* boot_tmp/
    cp rootdir/boot/initrd.img-* boot_tmp/initramfs
    cp rootdir/boot/vmlinuz-* boot_tmp/linux.efi

    umount boot_tmp
    rm -d boot_tmp
fi

# Create fstab
echo "📋 创建文件系统表..."
echo "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077,nofail 0 1" | tee rootdir/etc/fstab

# 配置主机名
echo "设置主机名: xiaomi-raphael"
echo "xiaomi-raphael" > rootdir/etc/hostname
cat > rootdir/etc/hosts << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   xiaomi-raphael
EOF

echo "✅ 主机名配置完成"

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

# 配置中国源
if [ "$USE_CHINA_MIRROR" = "true" ]; then
    echo -e "${CYAN}🔧 配置中国源 (USTC)${NC}"
    cat > rootdir/etc/apt/sources.list << 'EOF'
deb http://mirrors.ustc.edu.cn/debian/ trixie main contrib non-free non-free-firmware

deb http://mirrors.ustc.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware

deb http://mirrors.ustc.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
    echo -e "${GREEN}✅ 中国源配置完成${NC}"
    
    # 更新源列表
    echo -e "${CYAN}🔄 更新软件包列表...${NC}"
    if chroot rootdir apt update; then
        echo -e "${GREEN}✅ 软件包列表更新完成${NC}"
    else
        echo -e "${YELLOW}⚠️  软件包列表更新失败，可能是网络问题${NC}"
    fi
fi

# 清理
echo "🧹 清理系统..."
chroot rootdir apt clean
chroot rootdir rm -rf /var/lib/apt/lists/*

echo "✅ 系统清理完成"

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
echo "�️ 创建压缩包..."
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
