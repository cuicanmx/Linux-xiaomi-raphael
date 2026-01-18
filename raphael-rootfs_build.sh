set -e

# 配置变量
IMAGE_SIZE="8G"
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
echo "🌱 开始引导系统..."
echo "📥 下载: $distro_type $distro_version"

# Set mirror based on distribution type
 if [ "$distro_type" = "debian" ]; then
     mirror="http://deb.debian.org/debian/"
     echo "🔗 使用镜像源: $mirror"
     echo "执行命令: sudo debootstrap --arch=arm64 $distro_version rootdir $mirror"
     if sudo debootstrap --arch=arm64 "$distro_version" rootdir "$mirror"; then
         echo "✅ 系统引导完成"
     else
         echo "❌ debootstrap 失败"
         echo "💡 请检查网络连接和镜像源可用性"
         exit 1
     fi
 elif [ "$distro_type" = "ubuntu" ]; then
         # 使用ubuntu-base镜像替代debootstrap
         echo "🔗 使用ubuntu-base镜像"
         if [ "$distro_version" = "noble" ]; then
              ubuntu_version="24.04.3"
         elif [ "$distro_version" = "jammy" ]; then
             ubuntu_version="22.04"
         elif [ "$distro_version" = "focal" ]; then
             ubuntu_version="20.04"
         else
             echo "❌ 不支持的Ubuntu版本: $distro_version"
             exit 1
         fi
         
         # 检查镜像文件是否已存在
          if [ -f "ubuntu-base-$ubuntu_version-base-arm64.tar.gz" ]; then
              echo "ℹ️  镜像文件已存在，跳过下载"
          else
              wget -q --show-progress https://cdimage.ubuntu.com/ubuntu-base/releases/$ubuntu_version/release/ubuntu-base-$ubuntu_version-base-arm64.tar.gz || \
               wget -q --show-progress https://mirrors.tuna.tsinghua.edu.cn/ubuntu-base/releases/$ubuntu_version/release/ubuntu-base-$ubuntu_version-base-arm64.tar.gz
              if [ $? -ne 0 ]; then
                  echo "❌ 下载ubuntu-base镜像失败"
                  exit 1
              fi
          fi
      
      tar xzf ubuntu-base-$ubuntu_version-base-arm64.tar.gz -C rootdir
      if [ $? -ne 0 ]; then
          echo "❌ 解压ubuntu-base镜像失败"
          exit 1
      fi
     echo "✅ Ubuntu-base镜像解压完成"
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
    openssh-server openssh-client chrony 
    # 基础工具
    sudo vim wget curl iputils-ping
    # WiFi配置工具
    network-manager 
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
# Debian构建使用--stdin参数，Ubuntu构建不使用
if [ "$distro_type" = "debian" ]; then
    # 在chroot环境中使用passwd命令，通过管道自动输入密码
    chroot rootdir bash -c "echo '1234' | passwd --stdin root"
    if [ $? -eq 0 ]; then
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
else
    # Ubuntu构建不使用--stdin参数
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
    wget -q --show-progress https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img
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
    
    # 安装中文字体和语言包
    echo "🔤 安装中文字体和语言支持..."
    chroot rootdir apt install -y \
        fonts-arphic-uming \
        fonts-arphic-ukai \
        fonts-noto-cjk-extra \
        language-pack-gnome-zh-hans \
        language-pack-gnome-zh-hans-base \
        language-pack-zh-hans \
        language-pack-zh-hans-base \
        gnome-user-docs-zh-hans \
        libopencc-data \
        libmarisa0 \
        libopencc1.1 \
        libpinyin-data \
        libpinyin15 \
        ibus-libpinyin \
        ibus-table-wubi \
        libreoffice-help-common \
        libreoffice-l10n-zh-cn \
        libreoffice-help-zh-cn \
        thunderbird-locale-zh-cn \
        thunderbird-locale-zh-hans 2>/dev/null || echo "⚠️ 部分中文包安装失败，将继续..."
    echo "✅ 中文字体和语言包安装完成"
    
    # 配置用户和自动登录
    echo "👤 配置用户账户和自动登录..."
    chroot rootdir useradd -m -s /bin/bash luser
    echo "luser:luser" | chroot rootdir chpasswd
    echo "luser ALL=(ALL) NOPASSWD: ALL" >> rootdir/etc/sudoers
    chroot rootdir usermod -aG sudo luser
    echo "✅ 用户 luser 创建完成"
    
    # 配置显示管理器自动登录
    echo "🔧 配置显示管理器自动登录..."
    
    # 尝试使用 GDM3 自动登录配置
    if [ -d rootdir/etc/gdm3 ]; then
        cat > rootdir/etc/gdm3/daemon.conf << DAEMON
[daemon]
AutomaticLogin=luser
AutomaticLoginEnable=True
DAEMON
        chroot rootdir systemctl enable gdm3 || echo "⚠️  GDM3 启用失败"
    # 尝试使用 LightDM
    elif [ -d rootdir/etc/lightdm ]; then
        chroot rootdir mkdir -p /etc/lightdm/lightdm.conf.d
        cat > rootdir/etc/lightdm/lightdm.conf.d/50-autologin.conf << CONF
[Seat:*]
autologin-user=luser
autologin-user-timeout=0
user-session=${DESKTOP}
greeter-session=lightdm-gtk-greeter
CONF
        chroot rootdir systemctl enable lightdm || echo "⚠️  LightDM 启用失败"
    fi
    echo "✅ 显示管理器自动登录配置完成"
    
    # 启用显示服务和网络管理
    echo "🔧 启用显示和网络服务..."
    if [ "$distro_type" = "debian" ]; then
        chroot rootdir systemctl enable gdm3 2>/dev/null || chroot rootdir systemctl enable gdm 2>/dev/null || echo "⚠️  GDM 启用失败"
        chroot rootdir systemctl enable NetworkManager || echo "⚠️  NetworkManager 启用失败"
    elif [ "$distro_type" = "ubuntu" ]; then
        chroot rootdir systemctl enable gdm3 2>/dev/null || chroot rootdir systemctl enable gdm 2>/dev/null || echo "⚠️  GDM 启用失败"
        chroot rootdir systemctl enable NetworkManager || echo "⚠️  NetworkManager 启用失败"
    fi
    echo "✅ 服务启用完成"
    
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