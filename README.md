# Ubuntu/Debian for Xiaomi K20 Pro (Raphael)

# 本项目正在测试中，请勿使用

为小米 K20 Pro (代号: Raphael) 构建的 Ubuntu/Debian 系统镜像，支持在手机上运行完整的桌面Linux系统。

## 📋 项目特性

- ✅ **多发行版支持**: Ubuntu/Debian Server/Desktop 版本
- ✅ **完整桌面环境**: GNOME 桌面环境 (桌面版)
- ✅ **SSH 远程访问**: 服务器版支持 SSH 远程登录
- ✅ **硬件驱动支持**: 完整的硬件驱动和固件包
- ✅ **自动构建**: GitHub Actions 自动化构建流程
- ✅ **一键部署**: 简单的刷机流程

## 🚀 快速开始

### 下载镜像

前往 [GitHub Releases](https://github.com/your-username/ubuntu-xiaomi-raphael-uboot/releases) 下载最新的系统镜像：

- **服务器版**: 适合远程访问和服务器应用
- **桌面版**: 包含完整的图形界面

### 刷机步骤

1. **准备环境**:
   - 解锁手机 Bootloader
   - 安装 ADB 和 Fastboot 工具

2. **刷入系统**:
   ```bash
   # 进入 Fastboot 模式
   adb reboot bootloader
   
   # 不支持修改了分区的设备刷机，若你曾安装过windows请你务必恢复原分区表且分区名称也要恢复，否则会导致刷机失败
   # 清除 userdata 分区 (包含系统数据)
   fastboot erase userdata

   # 刷入 rootfs.img
   fastboot flash userdata .\rootfs.img
   ```

3. **首次启动**:
   - 系统将从 `userdata` 分区启动
   - 等待系统初始化完成

## 🔧 系统配置

### 默认凭据

**服务器版**:
- **用户名**: `root`
- **密码**: `123456`
- **SSH**: 已启用，允许 root 登录

**桌面版**:
- 使用系统默认配置
- 首次启动需要设置用户账户

### 网络配置

系统已预配置网络设置：
- DNS: 223.5.5.5
- 主机名: xiaomi-raphael
- 网络服务: systemd-networkd

## 🔨 构建说明

### GitHub Actions 构建

项目使用 GitHub Actions 自动化构建：

1. **内核构建**: 手动触发 `Build Kernel` 工作流
2. **系统镜像构建**: 手动触发 `Build RootFS` 工作流
3. **发布管理**: 构建完成后自动创建 Release

## ⚙️ 技术细节

### 内核版本
- **当前版本**: 6.18.2
- **源码仓库**: [GengWei1997/linux](https://github.com/GengWei1997/linux)
- **分支**: raphael-6.18

### 系统要求
- **设备**: 小米 K20 Pro (Raphael)
- **存储**: 至少 6GB 可用空间
- **内存**: 推荐 6GB+ RAM

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 贡献者

特别感谢以下项目的贡献：
- [@GengWei1997](https://github.com/GengWei1997) - 原项目
- [@Pc1598](https://github.com/Pc1598) - 提供内核源码
- [Aospa-raphael-unofficial/linux](https://github.com/Aospa-raphael-unofficial/linux) - 内核项目

## ⚠️ 免责声明

本项目仅供学习和研究使用。刷机有风险，操作前请备份重要数据，作者不对任何数据丢失或设备损坏负责。
