#!/bin/bash
set -euo pipefail

# =============================================================================
# 通用文件系统加密备份脚本
# =============================================================================

source "$(dirname "$0")/bash_modules.sh"

show_usage() {
    cat <<EOF
用法：
  $0 -f|--config_file <配置文件路径> -t|--type <备份类型>
选项：
  -f, --config_file    指定配置文件
  -t, --type           备份类型：daily, weekly, monthly
  -h, --help           显示帮助信息
EOF
}

failure() {
    local reason="$1"
    log::error "$reason"
    sc_send "【$TASK_NAME】备份失败（$BACKUP_TYPE）" "错误信息：$reason"
    exit 1
}

# ====================================
# 解析参数
# ====================================
CONFIG_FILE=""
BACKUP_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--config_file)
            CONFIG_FILE="${2-}"; shift 2 ;;
        --config_file=*) CONFIG_FILE="${1#*=}"; shift ;;
        -t|--type)
            BACKUP_TYPE="${2-}"; shift 2 ;;
        --type=*) BACKUP_TYPE="${1#*=}"; shift ;;
        -h|--help)
            show_usage; exit 0 ;;
        *)
            log::error "未知选项：$1"; show_usage; exit 1 ;;
    esac
done

[[ -z "$CONFIG_FILE" || -z "$BACKUP_TYPE" ]] && {
    log::error "必须指定配置文件和备份类型"
    show_usage
    exit 1
}

# ====================================
# 加载配置
# ====================================
[[ ! -f "$CONFIG_FILE" ]] && failure "配置文件不存在：$CONFIG_FILE"

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

[[ -z "${TASK_NAME:-}" || -z "${SOURCE_DIRECTORIES[*]:-}" ]] && failure "必须配置 TASK_NAME 和 SOURCE_DIRECTORIES"

# 日期与目录
DATE_STR=$(date +%Y-%m-%d_%H-%M-%S)
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$(dirname "$CONFIG_FILE")/backup}"
mkdir -p "$LOCAL_BACKUP_DIR"

ARCHIVE_NAME="backup_${BACKUP_TYPE}_${DATE_STR}.tar.gz"
ARCHIVE_PATH="$LOCAL_BACKUP_DIR/$ARCHIVE_NAME"

command -v tar >/dev/null || failure "未安装 tar"
command -v openssl >/dev/null || log::warn "未安装 openssl，加密将被跳过"
command -v BaiduPCS-Go >/dev/null || log::warn "未安装 BaiduPCS-Go，远程上传将被跳过"

# ====================================
# 构建打包参数
# ====================================
EXCLUDE_TAR_PARAMS=()
if [[ -n "${EXCLUDE_DIRECTORIES[*]:-}" ]]; then
    for dir in "${EXCLUDE_DIRECTORIES[@]}"; do
        EXCLUDE_TAR_PARAMS+=(--exclude="$dir")
    done
    log::info "设置排除目录 ${#EXCLUDE_DIRECTORIES[@]} 个"
else
    log::info "未配置排除目录"
fi

# ====================================
# 打包归档
# ====================================
log::info "开始打包..."
if ! tar -czf "$ARCHIVE_PATH" "${EXCLUDE_TAR_PARAMS[@]}" "${SOURCE_DIRECTORIES[@]}"; then
    failure "打包失败"
fi

# ====================================
# 加密（可选）
# ====================================
if [[ -n "${ENCRYPT_PASSWORD:-}" ]]; then
    ENC_PATH="$ARCHIVE_PATH.enc"
    log::info "加密归档..."
    if ! openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$ENCRYPT_PASSWORD" \
        -in "$ARCHIVE_PATH" -out "$ENC_PATH"; then
        failure "加密失败"
    fi
    rm -f "$ARCHIVE_PATH"
else
    ENC_PATH="$ARCHIVE_PATH"
    log::warn "未设置 ENCRYPT_PASSWORD，跳过加密"
fi

# ====================================
# 上传到百度网盘（可选）
# ====================================
if command -v BaiduPCS-Go >/dev/null && [[ -n "${FS_BAIDU_BASE:-}" ]]; then
    REMOTE_DIR="$FS_BAIDU_BASE/$BACKUP_TYPE"
    log::info "上传到百度网盘：$REMOTE_DIR"
    if ! BaiduPCS-Go upload "$ENC_PATH" "$REMOTE_DIR"; then
        failure "上传失败"
    fi
else
    log::warn "未配置 FS_BAIDU_BASE 或 BaiduPCS-Go，跳过上传"
fi

# ====================================
# 本地清理
# ====================================
RETAIN_COUNT=${FS_RETAIN_COUNT[$BACKUP_TYPE]:-0}
if (( RETAIN_COUNT > 0 )); then
    log::info "清理本地旧备份，保留最近 $RETAIN_COUNT 个"
    ls -1t "$LOCAL_BACKUP_DIR"/backup_"$BACKUP_TYPE"_*.tar.gz* 2>/dev/null \
        | tail -n +$((RETAIN_COUNT + 1)) \
        | xargs -r rm -f
else
    log::info "未设置保留数量，跳过本地清理"
fi

# ====================================
# 远程清理（可选）
# ====================================
if command -v BaiduPCS-Go >/dev/null && [[ -n "${FS_BAIDU_BASE:-}" && $RETAIN_COUNT -gt 0 ]]; then
    REMOTE_DIR="$FS_BAIDU_BASE/$BACKUP_TYPE"
    log::info "清理百度网盘备份，保留最近 $RETAIN_COUNT 个"
    remote_files=$(BaiduPCS-Go ls -time "$REMOTE_DIR" \
        | grep -oE "backup_${BACKUP_TYPE}_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.gz(\.enc)?" \
        | sort -r)
    index=0
    echo "$remote_files" | while read -r file; do
        index=$((index + 1))
        if (( index > RETAIN_COUNT )); then
            log::info "删除远程备份：$file"
            BaiduPCS-Go rm "$REMOTE_DIR/$file" || true
        fi
    done
else
    log::warn "跳过远程清理（未配置或保留数为 0）"
fi

log::info "✅ 备份完成：$BACKUP_TYPE（任务名：$TASK_NAME）"
exit 0

