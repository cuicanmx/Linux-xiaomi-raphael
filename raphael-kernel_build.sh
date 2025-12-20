#!/bin/bash

set -e

echo "🚀 ========================================="
echo "🔧 小米 Raphael 内核编译脚本 (优化版)"
echo "📅 开始时间: $(date)"
echo "=========================================="

# Check arguments
if [ $# -ne 1 ]; then
    echo "❌ 参数错误: 需要指定内核版本"
    echo "📋 用法: $0 <内核版本>"
    echo "💡 示例: $0 6.18"
    exit 1
fi

KERNEL_VERSION="$1"
echo "🎯 目标内核版本: $KERNEL_VERSION"
echo "📁 当前工作目录: $(pwd)"
echo "🔗 使用 raphael-$KERNEL_VERSION 分支"

# Check for ccache
echo "💾 检查 ccache 状态..."
if command -v ccache >/dev/null 2>&1; then
    echo "✅ ccache 已安装"
    ccache --version
else
    echo "⚠️  ccache 未安装，编译速度可能较慢"
fi

# Clone kernel source
echo "📥 克隆内核源代码..."
echo "🔗 从 https://github.com/GengWei1997/linux.git 克隆"
echo "🌿 使用分支: raphael-$KERNEL_VERSION"
git clone https://github.com/GengWei1997/linux.git --branch raphael-$KERNEL_VERSION --depth 1 linux

if [ $? -eq 0 ]; then
    echo "✅ 内核源代码克隆完成"
else
    echo "❌ 克隆失败，请检查网络连接和分支名称"
    exit 1
fi

cd linux
echo "📁 进入内核目录: $(pwd)"

# Configure kernel
echo "⚙️ 配置内核..."
echo "🔧 使用 defconfig 和 sm8150.config"
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig sm8150.config

if [ $? -eq 0 ]; then
    echo "✅ 内核配置完成"
else
    echo "❌ 内核配置失败"
    exit 1
fi

# Build kernel
echo "🔨 开始编译内核..."
echo "⏱️  开始时间: $(date '+%H:%M:%S')"
echo "⚡ 使用 $(nproc) 个CPU核心"
echo "💾 启用 ccache 加速"

if make -j$(nproc) ARCH=arm64 CROSS_COMPILE="ccache aarch64-linux-gnu-"; then
    echo "✅ 内核编译成功完成"
else
    echo "❌ 内核编译失败"
    exit 1
fi

echo "⏱️  编译结束时间: $(date '+%H:%M:%S')"

# Get kernel release version
echo "🏷️ 获取内核版本标识..."
_kernel_version="$(make kernelrelease -s)"
echo "📦 内核版本: $_kernel_version"

# Prepare kernel package directory
echo "📁 准备内核包目录..."
mkdir -p ../linux-xiaomi-raphael/boot

# Copy kernel files
echo "📋 复制内核文件..."
cp arch/arm64/boot/Image.gz ../linux-xiaomi-raphael/boot/vmlinuz-$_kernel_version
echo "✅ 复制内核镜像: vmlinuz-$_kernel_version"

# Explicitly build device tree files
echo "🔧 编译设备树文件..."
if make -j$(nproc) ARCH=arm64 CROSS_COMPILE="ccache aarch64-linux-gnu-" dtbs; then
    echo "✅ 设备树编译完成"
else
    echo "❌ 设备树编译失败"
    echo "💡 尝试单独编译 raphael 设备树..."
    if make -j$(nproc) ARCH=arm64 CROSS_COMPILE="ccache aarch64-linux-gnu-" sm8150-xiaomi-raphael.dtb; then
        echo "✅ 单独设备树编译完成"
    else
        echo "❌ 设备树编译完全失败"
        exit 1
    fi
fi

# Copy device tree files (try different possible locations)
echo "🔍 查找设备树文件..."
if [ -f "arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb" ]; then
    cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb ../linux-xiaomi-raphael/boot/dtb-$_kernel_version
    echo "✅ 复制设备树文件: dtb-$_kernel_version"
elif [ -f "arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb.gz" ]; then
    cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb.gz ../linux-xiaomi-raphael/boot/dtb-$_kernel_version.gz
    echo "✅ 复制压缩设备树文件: dtb-$_kernel_version.gz"
else
    echo "⚠️  未找到设备树文件，尝试查找其他位置..."
    echo "📂 检查设备树编译输出目录:"
    find arch/arm64/boot/dts/ -name "*.dtb" -type f 2>/dev/null | head -10
    echo "📂 检查 qcom 目录:"
    find arch/arm64/boot/dts/qcom/ -name "*" -type f 2>/dev/null | head -10
    echo "📂 检查整个编译输出:"
    find . -name "*raphael*" -type f 2>/dev/null | head -10
    echo "❌ 错误: 未找到设备树文件"
    echo "💡 请检查设备树配置和编译输出"
    exit 1
fi

# Update control file version
echo "📄 更新 DEBIAN/control 文件..."
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-raphael/DEBIAN/control
echo "✅ 版本号已更新为: $_kernel_version"

# Clean and install modules
echo "🧹 清理旧的模块目录..."
rm -rf ../linux-xiaomi-raphael/lib

echo "📦 安装内核模块..."
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../linux-xiaomi-raphael modules_install

if [ $? -eq 0 ]; then
    echo "✅ 模块安装完成"
else
    echo "❌ 模块安装失败"
    exit 1
fi

# Remove build directories from modules
echo "🧹 清理模块构建目录..."
rm -rf ../linux-xiaomi-raphael/lib/modules/**/build
echo "✅ 构建目录已清理"

# Return to original directory
cd ..
echo "📁 返回上级目录: $(pwd)"

# Clean up source directory
echo "🧹 清理内核源代码目录..."
rm -rf linux
echo "✅ 源代码目录已清理"

# Build Debian packages
echo "📦 开始构建 Debian 包..."

echo "🔨 构建 linux-xiaomi-raphael 包..."
dpkg-deb --build --root-owner-group linux-xiaomi-raphael
echo "✅ linux-xiaomi-raphael 包构建完成"

echo "🔨 构建 firmware-xiaomi-raphael 包..."
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
echo "✅ firmware-xiaomi-raphael 包构建完成"

echo "🔨 构建 alsa-xiaomi-raphael 包..."
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael
echo "✅ alsa-xiaomi-raphael 包构建完成"

# List generated packages
echo "📦 生成的包文件:"
ls -la *.deb

# Calculate package sizes
echo "📊 包文件大小统计:"
total_size=0
for deb in *.deb; do
    if [ -f "$deb" ]; then
        size=$(du -h "$deb" | cut -f1)
        size_bytes=$(du -b "$deb" | cut -f1)
        total_size=$((total_size + size_bytes))
        echo "  - $deb: $size"
    fi
done

PACKAGE_COUNT=$(ls -1 *.deb 2>/dev/null | wc -l)
total_size_human=$(echo "scale=2; $total_size/1024/1024" | bc)
echo "✅ 编译完成，生成了 $PACKAGE_COUNT 个包文件，总大小: ${total_size_human}MB"

echo ""
echo "🎉 ========================================="
echo "✨ 内核编译成功完成！"
echo "📅 结束时间: $(date)"
echo "🎯 内核版本: $_kernel_version"
echo "📦 生成的包文件:"
for deb in *.deb; do
    if [ -f "$deb" ]; then
        size=$(du -h "$deb" | cut -f1)
        echo "  - $deb ($size)"
    fi
done
echo "=========================================="
echo ""
echo "💡 下一步操作:"
echo "  1. 上传包文件到 GitHub Release"
echo "  2. 在 rootfs 构建中使用这些包"
echo "  3. 测试刷机"
echo "=========================================="