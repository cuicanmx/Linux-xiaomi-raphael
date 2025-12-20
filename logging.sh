#!/bin/bash

# 统一日志风格库
# 为小米Raphael项目提供一致的日志输出

# 日志级别定义
LOG_LEVEL_INFO="🔵"
LOG_LEVEL_SUCCESS="🟢"
LOG_LEVEL_WARNING="🟡"
LOG_LEVEL_ERROR="🔴"
LOG_LEVEL_DEBUG="🔵"

# 日志类型定义
LOG_TYPE_START="🚀"
LOG_TYPE_END="🎉"
LOG_TYPE_CONFIG="⚙️"
LOG_TYPE_BUILD="🔨"
LOG_TYPE_PACKAGE="📦"
LOG_TYPE_FILE="📁"
LOG_TYPE_NETWORK="🌐"
LOG_TYPE_SYSTEM="🖥️"
LOG_TYPE_SECURITY="🔒"
LOG_TYPE_SUCCESS="✅"
LOG_TYPE_WARNING="⚠️"
LOG_TYPE_ERROR="❌"

# 基础日志函数
log() {
    local level="$1"
    local type="$2"
    local message="$3"
    echo "$level $type $message"
}

# 特定日志函数
log_info() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_CONFIG" "$1"
}

log_success() {
    log "$LOG_LEVEL_SUCCESS" "$LOG_TYPE_SUCCESS" "$1"
}

log_warning() {
    log "$LOG_LEVEL_WARNING" "$LOG_TYPE_WARNING" "$1"
}

log_error() {
    log "$LOG_LEVEL_ERROR" "$LOG_TYPE_ERROR" "$1"
}

log_start() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_START" "$1"
}

log_end() {
    log "$LOG_LEVEL_SUCCESS" "$LOG_TYPE_END" "$1"
}

log_build() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_BUILD" "$1"
}

log_package() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_PACKAGE" "$1"
}

log_file() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_FILE" "$1"
}

log_network() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_NETWORK" "$1"
}

log_system() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_SYSTEM" "$1"
}

log_security() {
    log "$LOG_LEVEL_WARNING" "$LOG_TYPE_SECURITY" "$1"
}

log_config() {
    log "$LOG_LEVEL_INFO" "$LOG_TYPE_CONFIG" "$1"
}

# 分隔线函数
log_divider() {
    echo "=========================================="
}

# 标题函数
log_header() {
    local title="$1"
    log_divider
    echo "$LOG_LEVEL_INFO $LOG_TYPE_START $title"
    log_divider
}

# 带时间戳的日志
log_with_time() {
    local level="$1"
    local type="$2"
    local message="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $level $type $message"
}

# 检查命令执行结果
check_command() {
    local cmd="$1"
    local success_msg="$2"
    local error_msg="$3"
    
    if eval "$cmd"; then
        log_success "$success_msg"
        return 0
    else
        log_error "$error_msg"
        return 1
    fi
}

# 参数检查函数
check_arguments() {
    local expected_count="$1"
    local usage="$2"
    local example="$3"
    
    if [ $# -ne $((expected_count + 3)) ]; then
        log_error "参数错误: 需要 $expected_count 个参数"
        log_info "用法: $usage"
        log_info "示例: $example"
        exit 1
    fi
}

# 权限检查函数
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此操作需要root权限"
        exit 1
    fi
}

# 文件存在性检查
check_file_exists() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        log_success "找到 $description: $file"
        return 0
    else
        log_error "未找到 $description: $file"
        return 1
    fi
}

# 目录存在性检查
check_directory_exists() {
    local dir="$1"
    local description="$2"
    
    if [ -d "$dir" ]; then
        log_success "找到 $description: $dir"
        return 0
    else
        log_error "未找到 $description: $dir"
        return 1
    fi
}