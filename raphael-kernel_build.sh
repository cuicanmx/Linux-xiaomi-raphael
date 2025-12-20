#!/bin/bash

set -e

# 导入统一日志库
source ./logging.sh

log_header "小米 Raphael 内核编译脚本"
log_with_time "$LOG_LEVEL_INFO" "$LOG_TYPE_START" "开始时间: $(date)"

# 检查参数
check_arguments 1 "$0 <内核版本>" "$0 6.18"

KERNEL_VERSION="$1"
log_info "目标内核版本: $KERNEL_VERSION"

# 克隆内核源代码
log_network "克隆内核源代码..."
git clone https://github.com/GengWei1997/linux.git --branch raphael-$KERNEL_VERSION --depth 1 linux

cd linux

# 配置内核
log_config "配置内核..."
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig sm8150.config

# 编译内核
log_build "开始编译内核..."
make -j$(nproc) ARCH=arm64 CROSS_COMPILE="ccache aarch64-linux-gnu-"

# 获取内核版本标识
_kernel_version="$(make kernelrelease -s)"
log_package "内核版本: $_kernel_version"

# 准备内核包目录
mkdir -p ../linux-xiaomi-raphael/boot

# 复制内核文件
cp arch/arm64/boot/Image.gz ../linux-xiaomi-raphael/boot/vmlinuz-$_kernel_version

# 编译设备树文件
make -j$(nproc) ARCH=arm64 CROSS_COMPILE="ccache aarch64-linux-gnu-" dtbs

# 复制设备树文件
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb ../linux-xiaomi-raphael/boot/dtb-$_kernel_version

# 更新 control 文件版本
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-raphael/DEBIAN/control

# 清理和安装模块
rm -rf ../linux-xiaomi-raphael/lib
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../linux-xiaomi-raphael modules_install
rm -rf ../linux-xiaomi-raphael/lib/modules/**/build

# 返回上级目录并清理源代码
cd ..
rm -rf linux

# 构建 Debian 包
log_package "开始构建 Debian 包..."
dpkg-deb --build --root-owner-group linux-xiaomi-raphael
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael

log_end "内核编译成功完成！"
log_with_time "$LOG_LEVEL_SUCCESS" "$LOG_TYPE_END" "结束时间: $(date)"
log_info "内核版本: $_kernel_version"
