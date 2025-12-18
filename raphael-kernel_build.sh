git clone https://github.com/GengWei1997/linux.git --branch raphael-$1 --depth 1 linux
cd linux
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig sm8150.config
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
_kernel_version="$(make kernelrelease -s)"
mkdir ../linux-xiaomi-raphael/boot
cp arch/arm64/boot/Image.gz ../linux-xiaomi-raphael/boot/vmlinuz-$_kernel_version
cp arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dtb ../linux-xiaomi-raphael/boot/dtb-$_kernel_version
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-raphael/DEBIAN/control
rm -rf ../linux-xiaomi-raphael/lib
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../linux-xiaomi-raphael modules_install
rm ../linux-xiaomi-raphael/lib/modules/**/build
cd ..
rm -rf linux

dpkg-deb --build --root-owner-group linux-xiaomi-raphael
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael
