#!/usr/bin/env bash
set -euo pipefail

# ======================== 配置部分 ========================
readonly IMAGE_SIZE="6G"
readonly FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
readonly ROOT_PASSWORD="1234"
readonly HOSTNAME="xiaomi-raphael"

# 核心包列表
readonly BASE_PACKAGES=(
    systemd udev dbus bash-completion net-tools
    systemd-resolved wpasupplicant iw iproute2 sudo
    openssh-server openssh-client chrony
    vim wget curl iputils-ping
    network-manager wireless-regdb 
    alsa-ucm-conf alsa-utils initramfs-tools u-boot-tools ca-certificates
)

readonly KERNEL_PACKAGES=(
    linux-xiaomi-raphael
    firmware-xiaomi-raphael
    alsa-xiaomi-raphael
)

# ======================== 函数定义 ========================

log_info() {
    echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') $1" >&2
    exit 1
}

check_dependencies() {
    log_info "检查系统依赖..."
    local deps=(debootstrap mkfs.ext4 mount truncate 7z tune2fs)
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || log_error "必需的命令 '$dep' 未找到"
    done
}

validate_arguments() {
    [[ $# -ge 2 ]] || {
        echo "用法: $0 <发行版类型-变体> <内核版本> [use_china_mirror]"
        echo "示例: $0 debian-server 6.18 true"
        exit 1
    }
    [[ $(id -u) -eq 0 ]] || log_error "需要root权限"
}

parse_arguments() {
    local distro_arg=$1 kernel_version=$2 use_china_mirror="${3:-false}"
    IFS='-' read -r distro_type distro_variant <<< "$distro_arg"
    
    case "$distro_type" in
        debian) 
            distro_version="trixie"
            mirror="http://deb.debian.org/debian/"
            ;;
        *) log_error "不支持的发行版类型: $distro_type，仅支持 debian" ;;
    esac
    
    export DISTRO_TYPE="$distro_type"
    export DISTRO_VARIANT="$distro_variant"
    export DISTRO_VERSION="$distro_version"
    export KERNEL_VERSION="$kernel_version"
    export USE_CHINA_MIRROR="$use_china_mirror"
    export MIRROR="$mirror"
    
    log_info "参数解析完成: $distro_type-$distro_variant, 内核: $kernel_version"
}

check_kernel_packages() {
    log_info "检查内核包..."
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        if ! compgen -G "${pkg}*.deb" > /dev/null; then
            log_error "缺少内核包: ${pkg}*.deb"
        fi
    done
}

cleanup_environment() {
    log_info "清理环境..."
    
    # 卸载并清理rootdir
    if [[ -d "rootdir" ]]; then
        mount | grep "rootdir" | awk '{print $3}' | xargs -r umount -l 2>/dev/null || true
        rm -rf rootdir
    fi
    
    rm -f rootfs.img 2>/dev/null || true
}

create_and_mount_image() {
    log_info "创建IMG镜像文件..."
    truncate -s "$IMAGE_SIZE" rootfs.img
    mkfs.ext4 rootfs.img
    mkdir -p rootdir
    mount -o loop rootfs.img rootdir
}

bootstrap_system() {
    log_info "引导系统: $DISTRO_TYPE $DISTRO_VERSION"
    debootstrap --arch=arm64 "$DISTRO_VERSION" rootdir "$MIRROR" || \
        log_error "debootstrap失败"
}

mount_virtual_fs() {
    log_info "挂载虚拟文件系统..."
    mount --bind /dev rootdir/dev
    mount --bind /dev/pts rootdir/dev/pts
    mount -t proc proc rootdir/proc
    mount -t sysfs sys rootdir/sys
}

configure_system() {
    log_info "配置系统..."
    
    # 设置环境变量
    echo 'LC_ALL=C.UTF-8' > rootdir/etc/environment
    echo 'LANG=C.UTF-8' >> rootdir/etc/environment
    
    # 设置root密码
    echo "root:$ROOT_PASSWORD" | chroot rootdir chpasswd || log_error "设置密码失败"
    
    # 设置主机名
    echo "$HOSTNAME" > rootdir/etc/hostname
    echo -e "127.0.0.1\tlocalhost\n127.0.1.1\t$HOSTNAME" > rootdir/etc/hosts
    
    echo -e "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1\nPARTLABEL=cache /boot vfat umask=0077,nofail 0 1" | tee rootdir/etc/fstab
}

configure_network() {
    log_info "配置网络..."
    
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
    
    # 禁用传统network服务
    chroot rootdir systemctl disable networking.service 2>/dev/null || true
    
    # 启用systemd-networkd
    chroot rootdir systemctl enable systemd-networkd
}

configure_ssh() {
    [[ "$DISTRO_VARIANT" == *"desktop"* ]] && {
        log_info "桌面环境，跳过SSH配置"
        return 0
    }
    
    log_info "配置SSH..."
    
    # 备份原配置
    chroot rootdir cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # 写入新配置
    cat > rootdir/etc/ssh/sshd_config << 'EOF'
ListenAddress 0.0.0.0
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
    
    # 启用SSH服务
    chroot rootdir systemctl enable ssh
}

configure_china_mirror() {
    [[ "$USE_CHINA_MIRROR" != "true" ]] && return 0
    
    log_info "配置中国源..."
    
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

install_packages() {
    log_info "更新包列表..."
    chroot rootdir apt update || log_error "更新包列表失败"
    
    log_info "安装基础包..."
    chroot rootdir apt install -y --no-install-recommends "${BASE_PACKAGES[@]}" || \
        log_error "安装基础包失败"
    
    # 配置时间同步
    chroot rootdir systemctl enable chrony
    chroot rootdir systemctl start chrony
}

install_kernel() {
    log_info "安装内核包..."
    
    # 复制内核包
    log_info "📦 复制内核包到 chroot 环境..."
    cp linux-xiaomi-raphael*.deb rootdir/tmp/
    cp firmware-xiaomi-raphael*.deb rootdir/tmp/
    cp alsa-xiaomi-raphael*.deb rootdir/tmp/
    log_info "✅ 内核包复制完成"
    
    # 安装内核包
    log_info "🔧 安装定制内核包..."
    if chroot rootdir dpkg -i /tmp/linux-xiaomi-raphael.deb; then
        log_info "✅ linux-xiaomi-raphael 安装完成"
    else
        log_error "❌ linux-xiaomi-raphael 安装失败"
        exit 1
    fi

    if chroot rootdir dpkg -i /tmp/firmware-xiaomi-raphael.deb; then
        log_info "✅ firmware-xiaomi-raphael 安装完成"
    else
        log_error "❌ firmware-xiaomi-raphael 安装失败"
        exit 1
    fi

    if chroot rootdir dpkg -i /tmp/alsa-xiaomi-raphael.deb; then
        log_info "✅ alsa-xiaomi-raphael 安装完成"
    else
        log_error "❌ alsa-xiaomi-raphael 安装失败"
        exit 1
    fi
    
    # 更新initramfs
    chroot rootdir update-initramfs -c -k all
}

install_desktop() {
    [[ "$DISTRO_VARIANT" != "desktop" ]] && return 0
    
    log_info "安装桌面环境..."
    chroot rootdir apt install -y task-gnome-desktop || log_error "安装桌面失败"
    
    mkdir -p rootdir/var/lib/gdm
    touch rootdir/var/lib/gdm/run-initial-setup
    
    chroot rootdir systemctl set-default graphical.target
}

generate_boot_image() {
    [[ "$DISTRO_TYPE" != "debian" ]] && return 0
    [[ "$DISTRO_VARIANT" != "server" ]] && return 0
    
    log_info "生成boot镜像..."
    local boot_img="xiaomi-k20pro-boot.img"
    
    # 下载boot镜像
    wget -q --timeout=30 \
         https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img || {
        log_info "boot镜像下载失败，跳过"
        return 0
    }
    
    # 检查必要文件
    [[ ! -d "rootdir/boot" ]] && {
        log_info "boot目录不存在，跳过"
        return 0
    }
    
    # 挂载并复制文件
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
        log_info "boot镜像生成完成"
    else
        log_info "boot镜像挂载失败，跳过"
    fi
}

cleanup_and_package() {
    log_info "清理系统..."
    chroot rootdir apt clean all
    
    log_info "卸载文件系统..."
    for mountpoint in sys proc dev/pts dev; do
        mountpoint -q "rootdir/$mountpoint" && umount -l "rootdir/$mountpoint" 2>/dev/null || true
    done
    mountpoint -q "rootdir" && umount "rootdir" 2>/dev/null || true
    rm -rf rootdir
    
    log_info "调整文件系统UUID..."
    tune2fs -U "$FILESYSTEM_UUID" rootfs.img 2>/dev/null || true
    
    local output_file="raphael-${DISTRO_TYPE}-${DISTRO_VARIANT}-kernel-${KERNEL_VERSION}.7z"
    log_info "创建压缩包: $output_file"
    
    7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on "${output_file}" rootfs.img || \
        log_error "压缩包创建失败"
    
    echo "[SUCCESS] $(date +'%Y-%m-%d %H:%M:%S') 构建完成: $output_file"
}

# ======================== 主流程 ========================
main() {
    local start_time=$(date +%s)
    
    # 基础检查
    validate_arguments "$@"
    parse_arguments "$@"
    check_dependencies
    check_kernel_packages
    cleanup_environment
    
    # 创建和挂载镜像
    create_and_mount_image
    bootstrap_system
    mount_virtual_fs
    
    # 系统配置
    install_kernel
    install_packages
    configure_system
    configure_network
    configure_ssh
    configure_china_mirror
    # 生成boot镜像
    generate_boot_image
    
    # 清理和打包
    cleanup_and_package
    
    local end_time=$(date +%s)
    log_info "总用时: $((end_time - start_time))秒"
}

main "$@"