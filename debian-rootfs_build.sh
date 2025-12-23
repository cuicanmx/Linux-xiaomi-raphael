#!/usr/bin/env bash
set -euo pipefail

# 配置部分
readonly IMAGE_SIZE="6G"
readonly FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
readonly ROOT_PASSWORD="1234"
readonly HOSTNAME="xiaomi-raphael"

# 核心包列表
readonly BASE_PACKAGES=(
    systemd udev dbus bash-completion net-tools
    systemd-resolved wpasupplicant iw iproute2 sudo
    openssh-server openssh-client chrony
    vim wget curl iputils-ping zstd
    network-manager wireless-regdb 
    alsa-ucm-conf alsa-utils initramfs-tools u-boot-tools ca-certificates
)

readonly KERNEL_PACKAGES=(
    linux-xiaomi-raphael
    firmware-xiaomi-raphael
    alsa-xiaomi-raphael
)

# 检查依赖
check_dependencies() {
    local deps=(debootstrap mkfs.ext4 mount truncate 7z tune2fs zstd)
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || { echo "必需的命令 '$dep' 未找到" >&2; exit 1; }
    done
}

# 验证参数
validate_arguments() {
    [[ $# -ge 2 ]] || {
        echo "用法: $0 <变体> <内核版本> [--china-mirror]"
        echo "示例: $0 server 6.18 --china-mirror"
        exit 1
    }
    [[ $(id -u) -eq 0 ]] || { echo "需要root权限" >&2; exit 1; }
}

# 解析参数
parse_arguments() {
    local distro_arg=$1 kernel_version=$2 use_china_mirror="false"
    
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --china-mirror) use_china_mirror="true" ;;
            *) echo "未知参数: $1" >&2; exit 1 ;;
        esac
        shift
    done
    
    IFS='-' read -r distro_type distro_variant <<< "$distro_arg"
    
    case "$distro_type" in
        debian) 
            distro_version="trixie"
            mirror="http://deb.debian.org/debian/"
            ;;
        *) echo "不支持的发行版类型: $distro_type，仅支持 debian" >&2; exit 1 ;;
    esac
    
    export DISTRO_TYPE="$distro_type"
    export DISTRO_VARIANT="$distro_variant"
    export DISTRO_VERSION="$distro_version"
    export KERNEL_VERSION="$kernel_version"
    export USE_CHINA_MIRROR="$use_china_mirror"
    export MIRROR="$mirror"
}

# 检查内核包
check_kernel_packages() {
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        if ! compgen -G "${pkg}*.deb" > /dev/null; then
            echo "缺少内核包: ${pkg}*.deb" >&2
            exit 1
        fi
    done
}

# 清理环境
cleanup_environment() {
    echo "清理环境..."
    
    if [[ -d "rootdir" ]]; then
        mount | grep "rootdir" | awk '{print $3}' | xargs -r umount -l 2>/dev/null || true
        rm -rf rootdir
    fi
    
    rm -f rootfs.img 2>/dev/null || true
}

# 创建并挂载镜像
create_and_mount_image() {
    echo "创建IMG镜像文件..."
    truncate -s "$IMAGE_SIZE" rootfs.img
    mkfs.ext4 rootfs.img
    mkdir -p rootdir
    mount -o loop rootfs.img rootdir
}

# 引导系统
bootstrap_system() {
    echo "引导系统: $DISTRO_TYPE $DISTRO_VERSION"
    debootstrap --arch=arm64 "$DISTRO_VERSION" rootdir "$MIRROR" || { echo "debootstrap 失败" >&2; exit 1; }
}

# 挂载虚拟文件系统
mount_virtual_fs() {
    echo "挂载虚拟文件系统..."
    mount --bind /dev rootdir/dev
    mount --bind /dev/pts rootdir/dev/pts
    mount -t proc proc rootdir/proc
    mount -t sysfs sys rootdir/sys
}

# 配置系统
configure_system() {
    echo "配置系统..."
    
    echo "root:$ROOT_PASSWORD" | chroot rootdir chpasswd || { echo "设置密码失败" >&2; exit 1; }
    
    echo "$HOSTNAME" > rootdir/etc/hostname
    echo -e "127.0.0.1\tlocalhost\n127.0.1.1\t$HOSTNAME" > rootdir/etc/hosts
    
    echo -e "PARTLABEL=userdata\t/\text4\terrors=remount-ro,x-systemd.growfs\t0\t1" > rootdir/etc/fstab
    echo -e "PARTLABEL=cache\t/boot\tvfat\tumask=0077\t0\t0" >> rootdir/etc/fstab
}

# 配置网络
configure_network() {
    echo "配置网络..."
    
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
UseMTU=true
UseDNS=true
UseHostname=false
EOF
    
    chroot rootdir systemctl disable networking.service 2>/dev/null || true
    chroot rootdir systemctl enable systemd-networkd
}

# 配置SSH
configure_ssh() {
    [[ "$DISTRO_VARIANT" == *"desktop"* ]] && return 0
    
    echo "配置SSH..."
    
    chroot rootdir cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    cat > rootdir/etc/ssh/sshd_config << 'EOF'
ListenAddress 0.0.0.0
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
    
    chroot rootdir systemctl enable ssh
}

# 配置中国源
configure_china_mirror() {
    [[ "$USE_CHINA_MIRROR" != "true" ]] && return 0
    
    echo "配置中国源..."
    
    if [[ -f rootdir/etc/apt/sources.list ]]; then
        cp rootdir/etc/apt/sources.list rootdir/etc/apt/sources.list.bak
    fi
    
    cat > rootdir/etc/apt/sources.list << 'EOF'
deb http://mirrors.ustc.edu.cn/debian/ trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security/ trixie-security main contrib non-free non-free-firmware
EOF
}

# 安装包
install_packages() {
    echo "更新软件包列表..."
    chroot rootdir apt update || { echo "更新包列表失败" >&2; exit 1; }
    
    echo "安装基础包..."
    chroot rootdir apt install -y "${BASE_PACKAGES[@]}" || { echo "安装基础包失败" >&2; exit 1; }
    
    chroot rootdir systemctl enable chrony
    chroot rootdir systemctl start chrony
}

# 安装内核
install_kernel() {
    echo "安装内核包..."
    
    echo "复制内核包到 chroot 环境..."
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        cp "${pkg}"*.deb rootdir/tmp/
    done
    
    echo "安装定制内核包..."
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        if chroot rootdir dpkg -i "/tmp/${pkg}.deb"; then
            echo "$pkg 安装完成"
        else
            echo "$pkg 安装失败" >&2
            exit 1
        fi
    done
    
    chroot rootdir update-initramfs -c -k all
}

# 安装桌面
install_desktop() {
    [[ "$DISTRO_VARIANT" != "desktop" ]] && return 0
    
    echo "安装桌面环境..."
    chroot rootdir apt install -y task-gnome-desktop || { echo "安装桌面失败" >&2; exit 1; }
    
    mkdir -p rootdir/var/lib/gdm
    touch rootdir/var/lib/gdm/run-initial-setup
    
    chroot rootdir systemctl set-default graphical.target
}

# 生成boot镜像
generate_boot_image() {
    [[ "$DISTRO_VARIANT" != "server" ]] && return 0
    
    echo "生成boot镜像..."
    local boot_img="xiaomi-k20pro-boot.img"
    
    wget -q --timeout=30 \
         https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img || {
        echo "boot镜像下载失败，跳过"
        return 0
    }
    
    [[ ! -d "rootdir/boot" ]] && {
        echo "boot目录不存在，跳过"
        return 0
    }
    
    mkdir -p boot_tmp
    if mount -o loop "$boot_img" boot_tmp 2>/dev/null; then
        [[ -d "rootdir/boot/dtbs/qcom" ]] && {
            mkdir -p boot_tmp/dtbs/
            cp -r rootdir/boot/dtbs/qcom boot_tmp/dtbs/
        }
        
        local config_file=$(ls rootdir/boot/config-* 2>/dev/null | head -1)
        [[ -f "$config_file" ]] && cp "$config_file" boot_tmp/
        
        local initrd_file=$(ls rootdir/boot/initrd.img-* 2>/dev/null | head -1)
        [[ -f "$initrd_file" ]] && cp "$initrd_file" boot_tmp/initramfs
        
        local vmlinuz_file=$(ls rootdir/boot/vmlinuz-* 2>/dev/null | head -1)
        [[ -f "$vmlinuz_file" ]] && cp "$vmlinuz_file" boot_tmp/linux.efi
        
        umount boot_tmp 2>/dev/null || true
        rm -rf boot_tmp
        echo "boot镜像生成完成"
    else
        echo "boot镜像挂载失败，跳过"
    fi
}

# 清理和打包
cleanup_and_package() {
    echo "清理系统..."
    chroot rootdir apt clean all
    
    echo "卸载文件系统..."
    for mountpoint in sys proc dev/pts dev; do
        mountpoint -q "rootdir/$mountpoint" && umount -l "rootdir/$mountpoint" 2>/dev/null || true
    done
    mountpoint -q "rootdir" && umount "rootdir" 2>/dev/null || true
    rm -rf rootdir
    
    echo "调整文件系统UUID..."
    tune2fs -U "$FILESYSTEM_UUID" rootfs.img 2>/dev/null || true
    
    local output_file="${DISTRO_TYPE}-${DISTRO_VARIANT}-kernel-${KERNEL_VERSION}.7z"
    echo "创建压缩包: $output_file"
    
    7z a "${output_file}" rootfs.img || { echo "压缩包创建失败" >&2; exit 1; }
    
    echo "构建完成: $output_file"
}

# 主流程
main() {
    local start_time=$(date +%s)
    
    validate_arguments "$@"
    parse_arguments "$@"
    check_dependencies
    check_kernel_packages
    cleanup_environment
    
    create_and_mount_image
    bootstrap_system
    mount_virtual_fs
    
    install_packages
    configure_system
    configure_network
    configure_ssh

    install_desktop

    configure_china_mirror
    install_kernel
    
    generate_boot_image
    
    cleanup_and_package
    
    local end_time=$(date +%s)
    echo "总用时: $((end_time - start_time))秒"
}

main "$@"