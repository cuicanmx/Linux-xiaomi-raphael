# 仅在未设置环境变量时配置ccache
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

# 确保ccache目录存在
mkdir -p "$CCACHE_DIR"

# 确保ccache优先使用clang
export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

git clone https://github.com/cuicanmx/linux.git --branch raphael-$1 --depth 1 linux
cd linux
wget -P arch/arm64/configs https://raw.githubusercontent.com/cuicanmx/kernel-deb/refs/heads/main/raphael.config
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 defconfig raphael.config
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1
_kernel_version="$(make kernelrelease -s)"
mkdir -p ../linux-xiaomi-raphael/boot/dtbs/qcom
cp arch/arm64/boot/vmlinuz.efi ../linux-xiaomi-raphael/boot/vmlinuz-$_kernel_version
cp arch/arm64/boot/dts/qcom/sm8150*.dtb ../linux-xiaomi-raphael/boot/dtbs/qcom
cp .config ../linux-xiaomi-raphael/boot/config-$_kernel_version
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-raphael/DEBIAN/control
rm -rf ../linux-xiaomi-raphael/lib
make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../linux-xiaomi-raphael modules_install
rm ../linux-xiaomi-raphael/lib/modules/**/build
cd ..

dpkg-deb --build --root-owner-group linux-xiaomi-raphael
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael
