#!/usr/bin/env bash
set -euo pipefail

# ======================== 配置部分 ========================
# 终端配置 - 使用最简单的终端类型
export TERM=vt100

# 全局变量
readonly IMAGE_SIZE="6G"
readonly FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
readonly ROOT_PASSWORD="1234"
readonly HOSTNAME="xiaomi-raphael"

# 包列表 - 移除了ncurses-term和ncurses-base
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

# 日志函数 - 去掉所有颜色
log_info() {
    echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo "[SUCCESS] $(date +'%Y-%m-%d %H:%M:%S') $1"
}

log_warning() {
    echo "[WARNING] $(date +'%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') $1" >&2
    return 1
}

# 检查命令是否存在
check_dependency() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        log_error "必需的命令 '$cmd' 未找到，请安装后重试"
        exit 1
    fi
}

# 检查必需命令
check_dependencies() {
    log_info "检查系统依赖..."
    local deps=(debootstrap mkfs.ext4 mount truncate 7z tune2fs xargs awk grep)
    for dep in "${deps[@]}"; do
        check_dependency "$dep"
    done
    log_success "所有依赖已满足"
}

# 参数验证
validate_arguments() {
    if [[ $# -lt 2 ]]; then
        log_error "参数数量不足，期望 2-3 个参数"
        echo "用法: $0 <发行版类型-变体> <内核版本> [use_china_mirror]"
        echo "示例: $0 debian-server 6.18 true"
        exit 1
    fi
    
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "需要root权限运行此脚本"
        exit 1
    fi
    
    if [[ -z "${BASH_VERSION:-}" ]]; then
        log_error "请使用bash运行此脚本"
        exit 1
    fi
}

# 解析参数
parse_arguments() {
    local distro_arg=$1
    local kernel_version=$2
    local use_china_mirror="${3:-false}"
    
    # 解析发行版信息
    IFS='-' read -r distro_type distro_variant <<< "$distro_arg"
    
    # 设置发行版版本
    case "$distro_type" in
        debian) distro_version="trixie" ;;
        ubuntu) distro_version="jammy" ;;
        *) log_error "不支持的发行版类型: $distro_type" ;;
    esac
    
    # 设置镜像源
    case "$distro_type" in
        debian) mirror="http://deb.debian.org/debian/" ;;
        ubuntu) mirror="http://ports.ubuntu.com/ubuntu-ports/" ;;
    esac
    
    # 规范化use_china_mirror参数
    case "$use_china_mirror" in
        true|True|TRUE|1|yes|Yes|YES) use_china_mirror=true ;;
        *) use_china_mirror=false ;;
    esac
    
    # 导出全局变量
    export DISTRO_TYPE="$distro_type"
    export DISTRO_VARIANT="$distro_variant"
    export DISTRO_VERSION="$distro_version"
    export KERNEL_VERSION="$kernel_version"
    export USE_CHINA_MIRROR="$use_china_mirror"
    export MIRROR="$mirror"
    
    log_info "参数解析完成:"
    log_info "  类型: $DISTRO_TYPE"
    log_info "  变体: $DISTRO_VARIANT"
    log_info "  版本: $DISTRO_VERSION"
    log_info "  内核: $KERNEL_VERSION"
    log_info "  中国源: $USE_CHINA_MIRROR"
}

# 检查内核包
check_kernel_packages() {
    log_info "检查内核包文件..."
    local missing_packages=()
    
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        if ! compgen -G "${pkg}*.deb" > /dev/null; then
            missing_packages+=("${pkg}*.deb")
            log_error "  未找到: ${pkg}*.deb"
        else
            log_success "  找到: ${pkg}*.deb"
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_error "缺少必需的内核包: ${missing_packages[*]}"
        log_warning "当前目录文件列表:"
        ls -la *.deb 2>/dev/null || log_error "没有找到 .deb 文件"
        exit 1
    fi
    
    log_success "所有必需的内核包已就绪"
}

# 清理旧文件
cleanup_old_files() {
    log_info "清理旧的rootfs和镜像文件..."
    
    # 卸载并清理rootdir
    if [[ -d "rootdir" ]]; then
        # 优雅卸载
        mount | grep -E "rootdir/(sys|proc|dev)" | awk '{print $3}' | xargs -r umount -l 2>/dev/null || true
        mount | grep -E "rootdir$" | awk '{print $3}' | xargs -r umount -l 2>/dev/null || true
        rm -rf rootdir
        log_success "旧目录已清理"
    fi
    
    # 清理镜像文件
    if [[ -f "rootfs.img" ]]; then
        rm -f rootfs.img
        log_success "旧镜像文件已清理"
    fi
}

# 创建和挂载镜像
create_and_mount_image() {
    log_info "创建IMG镜像文件..."
    
    truncate -s "$IMAGE_SIZE" rootfs.img
    mkfs.ext4 rootfs.img
    mkdir -p rootdir
    mount -o loop rootfs.img rootdir
    
    log_success "镜像文件创建并挂载完成"
}

# 引导系统
bootstrap_system() {
    log_info "开始引导系统 (debootstrap)..."
    log_info "发行版: $DISTRO_TYPE $DISTRO_VERSION"
    log_info "镜像源: $MIRROR"
    
    if debootstrap --arch=arm64 "$DISTRO_VERSION" rootdir "$MIRROR"; then
        log_success "系统引导完成"
    else
        log_error "debootstrap 失败"
        log_warning "请检查网络连接和镜像源可用性"
        exit 1
    fi
}

# 挂载虚拟文件系统
mount_virtual_filesystems() {
    log_info "挂载虚拟文件系统..."
    
    mount --bind /dev rootdir/dev
    mount --bind /dev/pts rootdir/dev/pts
    mount -t proc proc rootdir/proc
    mount -t sysfs sys rootdir/sys
    
    log_success "虚拟文件系统挂载完成"
}

# 在chroot环境中执行命令 - 使用简单终端
run_in_chroot() {
    TERM=vt100 chroot rootdir bash -c "$1"
}

# 配置终端环境 - 简化版本
configure_terminal() {
    log_info "配置终端环境..."
    
    # 设置环境变量使用最简单的终端
    cat > rootdir/etc/environment << EOF
TERM=vt100
LC_ALL=C.UTF-8
LANG=C.UTF-8
EOF
    
    # 在bashrc中也设置，确保登录后生效
    echo 'export TERM=vt100' >> rootdir/etc/bash.bashrc
    
    log_success "终端环境配置完成"
}

# 更新软件包列表
update_package_list() {
    log_info "更新软件包列表..."
    
    if run_in_chroot "apt update"; then
        log_success "软件包列表更新完成"
    else
        log_error "软件包列表更新失败"
        exit 1
    fi
}

# 安装基础包
install_base_packages() {
    log_info "安装核心基础包..."
    
    if run_in_chroot "apt install -y --no-install-recommends ${BASE_PACKAGES[*]}"; then
        log_success "核心基础包安装完成"
    else
        log_error "核心基础包安装失败"
        exit 1
    fi
}

# 设置root密码
set_root_password() {
    log_info "设置Root密码..."
    
    if run_in_chroot "echo 'root:$ROOT_PASSWORD' | chpasswd"; then
        log_success "Root密码设置完成: root/$ROOT_PASSWORD"
    else
        log_error "Root密码设置失败"
        exit 1
    fi
}

# 配置SSH
configure_ssh() {
    if [[ "$DISTRO_VARIANT" == *"desktop"* ]]; then
        log_info "桌面环境检测: 跳过SSH配置"
        return 0
    fi
    
    log_info "配置SSH服务..."
    
    # 备份原配置
    run_in_chroot "cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak"
    
    # 写入新配置
    cat > rootdir/etc/ssh/sshd_config << 'EOF'
ListenAddress 0.0.0.0
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
    
    # 启用SSH服务
    run_in_chroot "systemctl enable ssh"
    
    log_success "SSH配置完成: 监听所有IP，允许root密码登录"
}

# 配置时间同步
configure_chrony() {
    log_info "配置时间同步..."
    
    run_in_chroot "systemctl enable chrony"
    run_in_chroot "systemctl start chrony"
    
    log_success "时间同步配置完成"
}

# 安装内核包
install_kernel_packages() {
    log_info "安装设备特定内核包..."
    
    # 复制内核包
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        cp "${pkg}"*.deb rootdir/tmp/
    done
    
    # 安装内核包
    for pkg in "${KERNEL_PACKAGES[@]}"; do
        log_info "安装 $pkg..."
        if run_in_chroot "dpkg -i /tmp/${pkg}*.deb"; then
            log_success "$pkg 安装完成"
        else
            log_error "$pkg 安装失败"
            exit 1
        fi
    done
    
    log_success "所有内核包安装完成"
}

# 配置网络
configure_network() {
    log_info "配置网络接口..."
    
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
    run_in_chroot "systemctl disable networking.service 2>/dev/null || true"
    
    # 启用systemd-networkd
    run_in_chroot "systemctl enable systemd-networkd systemd-resolved"
    
    log_success "网络配置完成: 所有接口自动获取IP"
}

# 更新initramfs
update_initramfs() {
    log_info "更新initramfs..."
    run_in_chroot "update-initramfs -c -k all"
    log_success "initramfs更新完成"
}

# 生成boot镜像 - 简化版，不添加表情符号
generate_boot_image() {
    if [[ "$DISTRO_TYPE" != "debian" ]] || [[ "$DISTRO_VARIANT" != "server" ]]; then
        log_info "当前构建 $DISTRO_TYPE-$DISTRO_VARIANT，跳过boot镜像生成"
        return 0
    fi
    
    log_info "生成boot镜像..."
    
    local boot_img="xiaomi-k20pro-boot.img"
    local boot_mount="boot_tmp"
    
    # 清理旧的临时文件
    rm -rf "$boot_mount"
    rm -f "$boot_img" 2>/dev/null || true
    
    # 1. 下载boot镜像
    log_info "下载boot镜像..."
    
    if wget -q --timeout=30 \
           https://github.com/GengWei1997/kernel-deb/releases/download/v1.0.0/xiaomi-k20pro-boot.img; then
        log_success "boot镜像下载完成"
    else
        log_warning "boot镜像下载失败，跳过boot镜像生成"
        return 0
    fi
    
    # 2. 验证下载的文件
    if [[ ! -f "$boot_img" ]]; then
        log_warning "下载的boot镜像文件不存在，跳过boot镜像生成"
        return 0
    fi
    
    # 3. 检查rootdir/boot目录是否存在
    if [[ ! -d "rootdir/boot" ]]; then
        log_warning "rootdir/boot 目录不存在，跳过boot镜像生成"
        return 0
    fi
    
    # 4. 检查内核文件是否存在
    log_info "检查内核文件..."
    
    # 如果任何关键文件缺失，跳过
    if [[ ! -d "rootdir/boot/dtbs/qcom" ]] || \
       ! ls rootdir/boot/config-* >/dev/null 2>&1 || \
       ! ls rootdir/boot/initrd.img-* >/dev/null 2>&1 || \
       ! ls rootdir/boot/vmlinuz-* >/dev/null 2>&1; then
        log_warning "缺少必要的内核文件，跳过boot镜像生成"
        return 0
    fi
    
    # 5. 创建挂载点并挂载
    log_info "准备挂载boot镜像..."
    mkdir -p "$boot_mount"
    
    if ! mount -o loop "$boot_img" "$boot_mount" 2>/dev/null; then
        log_warning "boot镜像挂载失败，跳过boot镜像生成"
        return 0
    fi
    
    log_success "boot镜像挂载成功"
    
    # 6. 复制文件
    log_info "复制内核文件到boot镜像..."
    
    # 复制设备树
    if [[ -d "rootdir/boot/dtbs/qcom" ]]; then
        mkdir -p "$boot_mount/dtbs/"
        cp -r "rootdir/boot/dtbs/qcom" "$boot_mount/dtbs/"
    fi
    
    # 复制配置文件（使用第一个找到的）
    local config_file=$(ls rootdir/boot/config-* 2>/dev/null | head -1)
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "$boot_mount/"
    fi
    
    # 复制initrd（使用第一个找到的）
    local initrd_file=$(ls rootdir/boot/initrd.img-* 2>/dev/null | head -1)
    if [[ -f "$initrd_file" ]]; then
        cp "$initrd_file" "$boot_mount/initramfs"
    fi
    
    # 复制vmlinuz（使用第一个找到的）
    local vmlinuz_file=$(ls rootdir/boot/vmlinuz-* 2>/dev/null | head -1)
    if [[ -f "$vmlinuz_file" ]]; then
        cp "$vmlinuz_file" "$boot_mount/linux.efi"
    fi
    
    # 7. 卸载并清理
    log_info "卸载boot镜像..."
    
    sleep 1
    umount "$boot_mount" 2>/dev/null || umount -l "$boot_mount" 2>/dev/null || true
    
    # 清理临时目录
    rm -rf "$boot_mount"
    
    # 检查boot镜像是否还存在
    if [[ -f "$boot_img" ]]; then
        log_success "boot镜像生成完成"
        return 0
    else
        log_warning "boot镜像文件丢失"
        return 0
    fi
}

# 配置fstab
configure_fstab() {
    log_info "创建文件系统表..."
    
    cat > rootdir/etc/fstab << 'EOF'
PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077,nofail 0 1
EOF
    
    log_success "文件系统表创建完成"
}

# 配置主机名
configure_hostname() {
    log_info "设置主机名: $HOSTNAME"
    
    echo "$HOSTNAME" > rootdir/etc/hostname
    cat > rootdir/etc/hosts << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   xiaomi-raphael
EOF
    
    log_success "主机名配置完成"
}

# 安装桌面环境
install_desktop_environment() {
    if [[ "$DISTRO_VARIANT" != "desktop" ]]; then
        return 0
    fi
    
    log_info "安装桌面环境..."
    
    if [[ "$DISTRO_TYPE" == "debian" ]]; then
        log_info "安装GNOME桌面环境..."
        if run_in_chroot "apt install -y task-gnome-desktop"; then
            log_success "GNOME桌面环境安装完成"
            
            # 配置GDM
            mkdir -p rootdir/var/lib/gdm
            touch rootdir/var/lib/gdm/run-initial-setup
            
            # 设置图形界面启动
            run_in_chroot "systemctl set-default graphical.target"
            
            log_success "桌面环境配置完成"
        else
            log_error "GNOME桌面环境安装失败"
            exit 1
        fi
    fi
}

# 配置中国源
configure_china_mirror() {
    if [[ "$USE_CHINA_MIRROR" != "true" ]]; then
        return 0
    fi
    
    log_info "配置中国源 (USTC)..."
    
    # 备份原始源列表
    if [[ -f rootdir/etc/apt/sources.list ]]; then
        cp rootdir/etc/apt/sources.list rootdir/etc/apt/sources.list.bak
    fi
    
    # 写入新的源列表
    case "$DISTRO_TYPE" in
        debian)
            cat > rootdir/etc/apt/sources.list << 'EOF'
deb http://mirrors.ustc.edu.cn/debian/ trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security/ trixie-security main contrib non-free non-free-firmware
EOF
            ;;
        ubuntu)
            cat > rootdir/etc/apt/sources.list << 'EOF'
deb http://mirrors.ustc.edu.cn/ubuntu-ports/ jammy main restricted universe multiverse
deb http://mirrors.ustc.edu.cn/ubuntu-ports/ jammy-updates main restricted universe multiverse
deb http://mirrors.ustc.edu.cn/ubuntu-ports/ jammy-backports main restricted universe multiverse
deb http://mirrors.ustc.edu.cn/ubuntu-ports/ jammy-security main restricted universe multiverse
EOF
            ;;
    esac
    
    # 更新源列表
    run_in_chroot "apt update"
    
    log_success "中国源配置完成"
}

# 清理系统
cleanup_system() {
    log_info "清理系统..."
    run_in_chroot "apt clean all"
    log_success "系统清理完成"
}

# 卸载文件系统
unmount_filesystems() {
    log_info "卸载虚拟文件系统..."
    
    # 卸载虚拟文件系统
    for mountpoint in sys proc dev/pts dev; do
        if mountpoint -q "rootdir/$mountpoint"; then
            umount -l "rootdir/$mountpoint" 2>/dev/null || true
        fi
    done
    
    # 卸载rootfs
    if mountpoint -q "rootdir"; then
        umount "rootdir" 2>/dev/null || true
    fi
    
    # 清理目录
    rm -rf rootdir
    
    log_success "文件系统卸载完成"
}

# 调整文件系统UUID
adjust_filesystem_uuid() {
    log_info "调整文件系统UUID..."
    tune2fs -U "$FILESYSTEM_UUID" rootfs.img
    log_success "文件系统UUID调整完成"
}

# 创建压缩包
create_archive() {
    local output_file="raphael-${DISTRO_TYPE}-${DISTRO_VARIANT}-kernel-${KERNEL_VERSION}.7z"
    
    log_info "创建压缩包: $output_file"
    
    if 7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on "${output_file}" rootfs.img; then
        log_success "压缩包创建成功: ${output_file}"
        log_info "文件大小: $(du -h "${output_file}" | cut -f1)"
    else
        log_error "压缩包创建失败"
        exit 1
    fi
}

# 打印构建总结
print_summary() {
    log_success "$DISTRO_TYPE-$DISTRO_VARIANT IMG镜像构建完成！"
    
    if [[ "$DISTRO_VARIANT" == "desktop" ]]; then
        log_info "桌面环境说明:"
        log_info "   - 默认显示管理器: GDM (GNOME Display Manager)"
        log_info "   - 登录账户: root/$ROOT_PASSWORD"
        log_info "   - 首次登录后会显示GNOME初始设置向导"
    else
        log_info "服务器环境说明:"
        log_info "   - SSH服务已启用，监听所有IP地址"
        log_info "   - 登录账户: root/$ROOT_PASSWORD"
        log_info "   - 网络接口已配置为自动获取IP"
    fi
}

# ======================== 主流程 ========================
main() {
    log_info "=========================================="
    log_info "开始构建系统镜像"
    log_info "=========================================="
    
    # 参数处理
    validate_arguments "$@"
    parse_arguments "$@"
    
    # 检查依赖
    check_dependencies
    
    # 检查内核包
    check_kernel_packages
    
    # 清理环境
    cleanup_old_files
    
    # 创建和挂载镜像
    create_and_mount_image
    
    # 引导系统
    bootstrap_system
    
    # 挂载虚拟文件系统
    mount_virtual_filesystems
    
    # 配置终端环境
    configure_terminal
    
    # 更新包列表
    update_package_list
    
    # 安装基础包
    install_base_packages
    
    # 系统配置
    set_root_password
    configure_ssh
    configure_chrony
    configure_network
    configure_fstab
    configure_hostname
    
    # 安装内核
    install_kernel_packages
    update_initramfs
    
    # 变体特定配置
    install_desktop_environment
    
    # 可选配置
    configure_china_mirror
    
    # 清理和卸载
    cleanup_system
    unmount_filesystems
    
    # 最终处理
    adjust_filesystem_uuid
    
    # 尝试生成boot镜像，但不强制
    generate_boot_image
    
    # 创建压缩包
    create_archive
    
    # 打印总结
    print_summary
    
    log_info "=========================================="
    log_info "构建流程完成"
    log_info "=========================================="
}

# 执行主函数
main "$@"