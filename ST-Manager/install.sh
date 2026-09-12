#!/usr/bin/env bash

# Project: ST-Manager (security-hardened fork)
# Repo: https://github.com/Kiro-Durandal/ST-beilu-Rapid_deployment

set -euo pipefail
IFS=$'\n\t'
umask 077

REPO_URL="https://github.com/Kiro-Durandal/ST-beilu-Rapid_deployment.git"
REPO_REF="main"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALL_DIR="$HOME/ST-Manager"
BACKUP_ROOT="$HOME/ST-Manager-backups"
TEMP_DIR="$(mktemp -d)"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
RESET='\033[0m'

log() { echo -e "${BLUE}[INFO] $1${RESET}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}" >&2; exit 1; }

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

require_termux() {
    [[ -n "${PREFIX:-}" && "$PREFIX" == *"com.termux"* ]] || \
        err "此安装器仅支持官方 Termux 环境。"
    [[ -n "${HOME:-}" && "$INSTALL_DIR" == "$HOME/ST-Manager" ]] || \
        err "安装目录安全检查失败。"
}

check_deps() {
    local packages=()

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v node >/dev/null 2>&1 || packages+=(nodejs)
    command -v python >/dev/null 2>&1 || packages+=(python)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl-tool)
    command -v pgrep >/dev/null 2>&1 || packages+=(procps)
    command -v zip >/dev/null 2>&1 || packages+=(zip)

    if (( ${#packages[@]} > 0 )); then
        log "安装缺失依赖: ${packages[*]}"
        pkg install -y "${packages[@]}" || err "依赖安装失败"
    else
        log "依赖检查通过；保留当前 Node.js 和 Python 版本。"
    fi
}

validate_scripts() {
    local root="$1"
    local script
    while IFS= read -r -d '' script; do
        bash -n "$script" || err "脚本语法检查失败: $script"
    done < <(find "$root" -type f -name '*.sh' -print0)
}

validate_hardened_release() {
    local root="$1"
    local gcli_file="$root/modules/gcli2api/functions.sh"
    [[ -f "$gcli_file" ]] || return 1
    grep -Fq 'GCLI_COMMIT="cdbaf37003a92de31b8a02512d43df3ed6de3411"' "$gcli_file" &&
        grep -Fq 'env HOST=127.0.0.1 PORT=7861' "$gcli_file" &&
        grep -Fq 'Do not source this file' "$root/core.sh"
}

install_project() {
    local source_dir
    local staged_dir="$TEMP_DIR/ST-Manager"
    local backup_dir=""

    if [[ -f "$SCRIPT_DIR/core.sh" && -d "$SCRIPT_DIR/modules" ]]; then
        source_dir="$SCRIPT_DIR"
        log "使用已下载并可审阅的本地安装文件..."
    else
        source_dir="$TEMP_DIR/repo/ST-Manager"
        log "从安全加固 Fork 下载管理器..."
        git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$TEMP_DIR/repo" || \
            err "仓库下载失败"
    fi
    [[ -d "$source_dir" ]] || err "仓库结构无效：缺少 ST-Manager 目录"
    validate_hardened_release "$source_dir" || \
        err "下载内容不包含预期的安全加固约束；拒绝安装。"

    cp -a "$source_dir" "$staged_dir"

    if [[ -f "$INSTALL_DIR/conf/settings.conf" ]]; then
        log "保留现有设置..."
        mkdir -p "$staged_dir/conf"
        cp "$INSTALL_DIR/conf/settings.conf" "$staged_dir/conf/settings.conf"
    fi

    validate_scripts "$staged_dir"
    chmod 700 "$staged_dir/conf"
    chmod 600 "$staged_dir/conf/settings.conf"
    chmod 755 "$staged_dir/core.sh" "$staged_dir/install.sh"
    find "$staged_dir/modules" -type f -name '*.sh' -exec chmod 755 {} \;

    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"

    if [[ -d "$INSTALL_DIR" ]]; then
        backup_dir="$BACKUP_ROOT/ST-Manager-$(date +%Y%m%d_%H%M%S)-$$"
        log "备份旧版本到 $backup_dir"
        mv "$INSTALL_DIR" "$backup_dir"
    fi

    if ! mv "$staged_dir" "$INSTALL_DIR"; then
        [[ -n "$backup_dir" && -d "$backup_dir" ]] && mv "$backup_dir" "$INSTALL_DIR"
        err "安装失败，已尝试恢复旧版本"
    fi

    if [[ -d "$PREFIX/bin" ]]; then
        log "创建全局命令 st-menu..."
        {
            echo '#!/usr/bin/env bash'
            printf 'exec bash %q "$@"\n' "$INSTALL_DIR/core.sh"
        } > "$PREFIX/bin/st-menu"
        chmod 755 "$PREFIX/bin/st-menu"
    fi
}

setup_autostart() {
    local choice bashrc marker command_line
    read -rp "是否在 Termux 启动时自动打开管理菜单？(y/N): " choice
    [[ "$choice" =~ ^[Yy]$ ]] || return 0

    bashrc="$HOME/.bashrc"
    marker="# >>> ST-Manager autostart >>>"
    printf -v command_line 'bash %q' "$INSTALL_DIR/core.sh"
    touch "$bashrc"

    if grep -Fq -- "$marker" "$bashrc"; then
        success "自启动已经启用，未重复写入。"
        return 0
    fi

    {
        echo
        echo "$marker"
        echo "$command_line"
        echo "# <<< ST-Manager autostart <<<"
    } >> "$bashrc"
    success "已安全追加自启动配置；原有 .bashrc 内容未改动。"
}

main() {
    clear
    echo -e "${BLUE}=== ST-Manager 安全加固版安装器 ===${RESET}"
    require_termux
    check_deps
    install_project

    echo -e "${BLUE}====================================${RESET}"
    success "安装完成"
    echo -e "运行: ${YELLOW}st-menu${RESET}"

    setup_autostart

    local start
    read -rp "现在启动？(y/N): " start
    if [[ "$start" =~ ^[Yy]$ ]]; then
        exec bash "$INSTALL_DIR/core.sh"
    fi
}

main "$@"
