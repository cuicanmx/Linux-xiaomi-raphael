# 统一日志风格指南

## 概述

本项目已实现统一的日志风格，通过 `logging.sh` 库提供一致的日志输出格式。所有脚本现在使用相同的日志函数，确保整个项目的日志风格一致。

## 日志库功能

### 日志级别
- `🔵 INFO` - 普通信息
- `🟢 SUCCESS` - 成功操作
- `🟡 WARNING` - 警告信息
- `🔴 ERROR` - 错误信息

### 日志类型
- `🚀 START` - 开始操作
- `🎉 END` - 结束操作
- `⚙️ CONFIG` - 配置相关
- `🔨 BUILD` - 构建相关
- `📦 PACKAGE` - 包管理相关
- `📁 FILE` - 文件操作相关
- `🌐 NETWORK` - 网络相关
- `🖥️ SYSTEM` - 系统相关
- `🔒 SECURITY` - 安全相关

## 主要日志函数

### 基础日志函数
```bash
log_info "信息内容"
log_success "成功信息"
log_warning "警告信息"
log_error "错误信息"
```

### 特定类型日志
```bash
log_start "开始操作"
log_end "结束操作"
log_build "构建信息"
log_package "包信息"
log_file "文件操作"
log_network "网络操作"
log_system "系统操作"
log_security "安全信息"
```

### 辅助函数
```bash
log_header "标题"        # 带分隔线的标题
log_divider              # 分隔线
log_with_time "信息内容"  # 带时间戳的日志
```

### 检查函数
```bash
check_command "命令" "成功信息" "错误信息"
check_arguments 数量 "用法" "示例"
check_root
check_file_exists "文件路径" "描述"
check_directory_exists "目录路径" "描述"
```

## 使用示例

### 在脚本中使用
```bash
#!/bin/bash
set -e

# 导入日志库
source ./logging.sh

log_header "脚本标题"
log_with_time "$LOG_LEVEL_INFO" "$LOG_TYPE_START" "开始时间: $(date)"

# 检查参数
check_arguments 2 "$0 <参数1> <参数2>" "$0 value1 value2"

# 执行命令并检查结果
check_command \
    "make -j$(nproc) build" \
    "构建成功" \
    "构建失败"

log_end "脚本完成"
```

## 已修改的文件

1. **logging.sh** - 统一日志库
2. **raphael-kernel_build.sh** - 内核编译脚本
3. **raphael-rootfs_build.sh** - rootfs构建脚本

## 修改内容

### 统一了以下方面：
1. **表情符号使用** - 所有脚本使用相同的表情符号集
2. **日志格式** - 统一的格式：`[时间戳] 级别 类型 信息`
3. **错误处理** - 使用统一的错误检查函数
4. **信息层级** - 清晰的日志级别标识
5. **代码结构** - 使用函数替代重复的echo语句

### 主要改进：
- 提高了代码的可读性和可维护性
- 统一的错误处理机制
- 更好的日志信息分类
- 时间戳支持
- 参数验证函数

## 使用建议

1. 新脚本应导入并使用 `logging.sh` 库
2. 根据操作类型选择合适的日志函数
3. 使用检查函数简化错误处理
4. 保持日志信息的简洁和一致性

## 注意事项

- 确保 `logging.sh` 文件与脚本在同一目录
- 所有日志函数都支持中文内容
- 错误信息会自动退出脚本（exit 1）
- 时间戳格式：YYYY-MM-DD HH:MM:SS