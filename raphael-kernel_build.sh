#!/bin/bash
# raphael-kernel_build.sh - 内核构建脚本（添加CC参数支持ccache）

# ==================== 参数验证 ====================
KERNEL_VERSION="$1"

if [ -z "$KERNEL_VERSION" ]; then
    echo "错误: 请提供内核版本号"
    echo "用法: $0 <内核版本号>"
    exit 1
fi

echo "开始构建内核版本: $KERNEL_VERSION"

# ==================== 设置ccache环境 ====================
# 设置ccache环境变量
export CCACHE_DIR="${CCACHE_DIR:-/home/runner/.ccache}"
export CCACHE_MAXSIZE="10G"
export CCACHE_COMPRESS=1
export CCACHE_SLOPPINESS="file_macro,locale,time_macros"

# 确保ccache目录存在
mkdir -p "$CCACHE_DIR"

# 显示ccache状态
echo "ccache状态检查:"
ccache --show-stats 2>/dev/null || echo "ccache未安装"

# ==================== 原始命令序列 - 仅修改make命令添加CC参数 ====================
echo "执行构建命令序列..."

# 命令1: 克隆代码
echo "克隆内核源代码..."
git clone https://github.com/GengWei1997/linux.git --branch raphael-$KERNEL_VERSION --depth 1 linux

# 命令2: 进入目录
cd linux

# 命令3: 配置内核（添加CC="ccache gcc"）
echo "配置内核..."
make -j$(nproc) ARCH=arm64 CC="ccache gcc" defconfig sm8150.config

# 命令4: 编译内核（添加CC="ccache gcc"）
echo "编译内核..."
make -j$(nproc) ARCH=arm64 CC="ccache gcc"

# 命令5: 获取内核版本（不需要ccache）
_kernel_version="$(make kernelrelease -s)"
echo "内核版本: $_kernel_version"

# 命令6: 创建boot目录
mkdir ../linux-xiaomi-raphael/boot

# 命令7: 复制内核镜像
cp arch/arm64/boot/Image.gz ../linux-xiaomi-raphael/boot/vmlinuz-$_kernel_version

# 命令8: 复制设备树文件
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb ../linux-xiaomi-raphael/boot/dtb-$_kernel_version

# 命令9: 更新控制文件
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-raphael/DEBIAN/control

# 命令10: 清理旧的模块目录
rm -rf ../linux-xiaomi-raphael/lib

# 命令11: 安装内核模块（添加CC="ccache gcc"）
make -j$(nproc) ARCH=arm64 CC="ccache gcc" INSTALL_MOD_PATH=../linux-xiaomi-raphael modules_install

# 命令12: 清理构建文件
rm ../linux-xiaomi-raphael/lib/modules/**/build

# 命令13: 返回上级目录
cd ..

# 命令14: 清理源码目录
rm -rf linux

# 命令15: 构建linux包
dpkg-deb --build --root-owner-group linux-xiaomi-raphael

# 命令16: 构建firmware包
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael

# 命令17: 构建alsa包
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael

# ==================== 显示构建结果 ====================
echo "构建完成!"
echo "生成的包:"
ls -la *.deb 2>/dev/null || echo "未找到.deb文件"

# 显示ccache统计
if command -v ccache >/dev/null 2>&1; then
    echo ""
    echo "ccache统计信息:"
    ccache --show-stats
fi

echo "内核版本: $_kernel_version"
echo "构建时间: $(date)"