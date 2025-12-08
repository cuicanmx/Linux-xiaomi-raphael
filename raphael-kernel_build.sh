git clone https://github.com/GengWei1997/linux.git --branch raphael-$1 --depth 1 linux
cd linux
wget -P arch/arm64/configs https://raw.githubusercontent.com/GengWei1997/kernel-deb/refs/heads/main/raphael.config
make -j$(nproc) ARCH=arm64 LLVM=1 defconfig raphael.config
make -j$(nproc) ARCH=arm64 LLVM=1
_kernel_version="$(make kernelrelease -s)"
mkdir -p ../linux-xiaomi-raphael/boot/dtbs/qcom
cp arch/arm64/boot/vmlinuz.efi ../linux-xiaomi-raphael/boot/vmlinuz-$_kernel_version
cp arch/arm64/boot/dts/qcom/sm8150*.dtb ../linux-xiaomi-raphael/boot/dtbs/qcom
cp .config ../linux-xiaomi-raphael/boot/config-$_kernel_version
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-raphael/DEBIAN/control
rm -rf ../linux-xiaomi-raphael/lib
make -j$(nproc) ARCH=arm64 LLVM=1 INSTALL_MOD_PATH=../linux-xiaomi-raphael modules_install
rm ../linux-xiaomi-raphael/lib/modules/**/build
cd ..
rm -rf linux

dpkg-deb --build --root-owner-group linux-xiaomi-raphael
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael
