#!/usr/bin/env bash

# ==============================================================================
# Project: ST-Manager (security-hardened fork)
# ==============================================================================

set -o pipefail
umask 077

DIR=$(cd "$(dirname "$0")" && pwd)
APP_DIR="$DIR"
CONF_DIR="$DIR/conf"
MODULES_DIR="$DIR/modules"
SETTINGS_FILE="$CONF_DIR/settings.conf"
UPDATE_REPO_URL="https://github.com/Kiro-Durandal/ST-beilu-Rapid_deployment.git"
UPDATE_REPO_REF="main"
BACKUP_ROOT="$HOME/ST-Manager-backups"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
RESET='\033[0m'

declare -A MENU_TEXTS
declare -A FUNCTION_MAP
declare -A MODULE_GROUP_ORDER
declare -A GROUP_TO_MODULE_MAP

readonly MAIN_GROUP_ORDER=("SillyTavern 管理" "gcli2api 管理" "系统管理")

log() { echo -e "${BLUE}[INFO] $1${RESET}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}" >&2; }

pause() {
    read -rsp $'按任意键继续...\n' -n 1
}

# ==============================================================================
# Settings Management
# ==============================================================================
validate_proxy_url() {
    local url="$1"
    local pattern='^(https?|socks5h?)://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})$'
    local port

    [[ "$url" =~ $pattern ]] || return 1
    port="${BASH_REMATCH[3]}"
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

save_settings() {
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"
    {
        printf 'USE_PROXY=%s\n' "$USE_PROXY"
        printf 'PROXY_URL=%s\n' "$PROXY_URL"
        printf 'DEBUG_MODE=%s\n' "$DEBUG_MODE"
    } > "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE"
}

load_settings() {
    local key value
    USE_PROXY=false
    PROXY_URL=""
    DEBUG_MODE=false

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        save_settings
    fi

    # Do not source this file. Parse only known keys as inert text.
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value:1:${#value}-2}"
        fi
        case "$key" in
            USE_PROXY)
                [[ "$value" == "true" || "$value" == "false" ]] && USE_PROXY="$value"
                ;;
            PROXY_URL)
                PROXY_URL="$value"
                ;;
            DEBUG_MODE)
                [[ "$value" == "true" || "$value" == "false" ]] && DEBUG_MODE="$value"
                ;;
        esac
    done < "$SETTINGS_FILE"

    chmod 600 "$SETTINGS_FILE" 2>/dev/null || true

    if [[ "$USE_PROXY" == "true" ]]; then
        if validate_proxy_url "$PROXY_URL"; then
            export http_proxy="$PROXY_URL"
            export https_proxy="$PROXY_URL"
            export ALL_PROXY="$PROXY_URL"
            log "已启用代理: $PROXY_URL"
        else
            warn "已忽略格式不安全的代理地址，并关闭代理。"
            USE_PROXY=false
            PROXY_URL=""
            save_settings
            unset http_proxy https_proxy ALL_PROXY
        fi
    else
        unset http_proxy https_proxy ALL_PROXY
    fi
}

# ==============================================================================
# Module System
# ==============================================================================
validate_menu_conf() {
    [[ -f "$1" ]]
}

load_modules() {
    MENU_TEXTS=()
    FUNCTION_MAP=()
    MODULE_GROUP_ORDER=()
    GROUP_TO_MODULE_MAP=()

    local module_dir module_name funcs_file menu_file current_group line key text item sys_group
    for module_dir in "$MODULES_DIR"/*/; do
        [[ -d "$module_dir" ]] || continue

        module_name=$(basename "$module_dir")
        funcs_file="${module_dir}functions.sh"
        menu_file="${module_dir}menu.conf"
        [[ -f "$funcs_file" && -f "$menu_file" ]] || continue

        # shellcheck source=/dev/null
        source "$funcs_file"
        current_group=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
            if [[ "$line" =~ ^\[(.*)\] ]]; then
                current_group="${BASH_REMATCH[1]%$'\r'}"
                GROUP_TO_MODULE_MAP["$current_group"]="$module_name"
            elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                text="${BASH_REMATCH[2]}"
                key=$(echo "$key" | tr -d '[:space:]')
                text=$(echo "$text" | tr -d '\r')
                MENU_TEXTS["$key"]="$text"
                FUNCTION_MAP["$key"]="$key"
                if [[ -z "${MODULE_GROUP_ORDER[$current_group]}" ]]; then
                    MODULE_GROUP_ORDER["$current_group"]="$key"
                else
                    MODULE_GROUP_ORDER["$current_group"]="${MODULE_GROUP_ORDER[$current_group]} $key"
                fi
            fi
        done < "$menu_file"
    done

    sys_group="系统管理"
    local sys_items=("fix_env:修复运行环境" "update_self:更新管理工具" "settings_menu:系统设置" "visit_github:访问 GitHub" "visit_discord:加入 Discord 粉丝群")
    for item in "${sys_items[@]}"; do
        key="${item%:*}"
        text="${item#*:}"
        MENU_TEXTS["$key"]="$text"
        FUNCTION_MAP["$key"]="$key"
    done
    MODULE_GROUP_ORDER["$sys_group"]="fix_env update_self settings_menu visit_github visit_discord"
}

# ==============================================================================
# System Functions
# ==============================================================================
fix_env() {
    local packages=()
    if [[ -z "${PREFIX:-}" || "$PREFIX" != *"com.termux"* ]]; then
        warn "非 Termux 环境，未修改系统软件。"
        pause
        return
    fi

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v node >/dev/null 2>&1 || packages+=(nodejs)
    command -v python >/dev/null 2>&1 || packages+=(python)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl-tool)
    command -v pgrep >/dev/null 2>&1 || packages+=(procps)
    command -v zip >/dev/null 2>&1 || packages+=(zip)

    if (( ${#packages[@]} == 0 )); then
        success "运行环境完整；没有替换现有 Node.js。"
    elif pkg install -y "${packages[@]}"; then
        success "已安装缺失依赖: ${packages[*]}"
    else
        err "部分依赖安装失败。"
    fi
    pause
}

validate_script_tree() {
    local root="$1" script
    while IFS= read -r -d '' script; do
        bash -n "$script" || return 1
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

update_self() {
    local update_tmp source_dir backup_dir
    update_tmp=$(mktemp -d)
    source_dir="$update_tmp/repo/ST-Manager"
    backup_dir="$BACKUP_ROOT/ST-Manager-$(date +%Y%m%d_%H%M%S)-$$"

    echo -e "${BLUE}正在下载并检查更新...${RESET}"
    if ! git clone --depth 1 --branch "$UPDATE_REPO_REF" "$UPDATE_REPO_URL" "$update_tmp/repo"; then
        rm -rf -- "$update_tmp"
        err "更新下载失败，请检查网络或代理设置。"
        pause
        return
    fi
    if [[ ! -d "$source_dir" ]] ||
       ! validate_script_tree "$source_dir" ||
       ! validate_hardened_release "$source_dir"; then
        rm -rf -- "$update_tmp"
        err "更新包结构、Shell 语法或安全约束检查失败；当前版本未改动。"
        pause
        return
    fi

    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    log "备份当前版本到 $backup_dir"
    if ! mv "$APP_DIR" "$backup_dir"; then
        rm -rf -- "$update_tmp"
        err "无法创建更新备份；已取消更新。"
        pause
        return
    fi

    if ! cp -a "$source_dir" "$APP_DIR"; then
        rm -rf -- "$APP_DIR"
        mv "$backup_dir" "$APP_DIR"
        rm -rf -- "$update_tmp"
        err "更新安装失败，已恢复旧版本。"
        pause
        return
    fi

    if [[ -f "$backup_dir/conf/settings.conf" ]]; then
        mkdir -p "$APP_DIR/conf"
        cp "$backup_dir/conf/settings.conf" "$APP_DIR/conf/settings.conf"
    fi
    chmod 700 "$APP_DIR/conf"
    chmod 600 "$APP_DIR/conf/settings.conf"
    chmod 755 "$APP_DIR/core.sh" "$APP_DIR/install.sh"
    find "$APP_DIR/modules" -type f -name '*.sh' -exec chmod 755 {} \;
    rm -rf -- "$update_tmp"

    success "更新完成，旧版本已保留为可恢复备份。"
    exec bash "$APP_DIR/core.sh"
}

settings_menu() {
    local choice url
    while true; do
        clear
        echo -e "${BLUE}=== 系统设置 ===${RESET}"
        echo -e "代理仅接受 http、https、socks5 或 socks5h 的 主机:端口 格式。"
        echo -e "${BLUE}----------------------------------------------${RESET}"
        echo -e "1) 切换代理开关 (当前: $USE_PROXY)"
        echo -e "2) 设置代理地址 (当前: $PROXY_URL)"
        echo -e "0) 返回"
        read -rp "请选择: " choice
        case "$choice" in
            1)
                if [[ "$USE_PROXY" == "true" ]]; then
                    USE_PROXY=false
                elif validate_proxy_url "$PROXY_URL"; then
                    USE_PROXY=true
                else
                    err "请先设置有效代理地址。"
                    pause
                    continue
                fi
                save_settings
                load_settings
                ;;
            2)
                read -rp "例如 http://127.0.0.1:7890 : " url
                if validate_proxy_url "$url"; then
                    PROXY_URL="$url"
                    save_settings
                    success "代理地址已保存。"
                else
                    err "格式无效。禁止用户名、密码、路径、空格及 Shell 特殊字符。"
                fi
                pause
                ;;
            0) break ;;
        esac
    done
}

visit_github() {
    local url="https://github.com/Kiro-Durandal/ST-beilu-Rapid_deployment"
    echo -e "请访问: ${GREEN}$url${RESET}"
    if command -v termux-open-url >/dev/null 2>&1; then
        termux-open-url "$url"
    fi
    pause
}

visit_discord() {
    local url="https://discord.gg/agHeDq9bqU"
    echo -e "请访问: ${GREEN}$url${RESET}"
    if command -v termux-open-url >/dev/null 2>&1; then
        termux-open-url "$url"
    fi
    pause
}

# ==============================================================================
# Menus
# ==============================================================================
show_banner() {
    clear
    echo -e "${BLUE}==============================================${RESET}"
    echo -e "${GREEN}        与你之歌 v1.1（安全加固版）       ${RESET}"
    echo -e "${BLUE}==============================================${RESET}"
    echo -e "仅供学习与研究；请遵守相关服务条款和当地法律。"
    echo -e "${BLUE}==============================================${RESET}"
}

show_group_menu() {
    local group_name="$1" module_name i key choice func
    while true; do
        clear
        echo -e "${BLUE}=== $group_name ===${RESET}"
        module_name="${GROUP_TO_MODULE_MAP[$group_name]}"
        if [[ "$module_name" == "sillytavern" ]] && declare -f st_status_text >/dev/null; then
            st_status_text
        elif [[ "$module_name" == "gcli2api" ]] && declare -f gcli_status_text >/dev/null; then
            gcli_status_text
        fi
        echo -e "${BLUE}----------------------------------------------${RESET}"

        i=1
        declare -A active_options=()
        if [[ -n "${MODULE_GROUP_ORDER[$group_name]}" ]]; then
            for key in ${MODULE_GROUP_ORDER[$group_name]}; do
                echo -e "  ${GREEN}$i)${RESET} ${MENU_TEXTS[$key]}"
                active_options[$i]="$key"
                ((i++))
            done
        fi

        echo -e "\n${RED}0)${RESET} 返回上一级"
        read -rp "请选择 [0-$((i-1))]: " choice
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ -n "${active_options[$choice]}" ]]; then
            func="${FUNCTION_MAP[${active_options[$choice]}]}"
            if declare -f "$func" >/dev/null; then
                "$func"
            else
                err "未找到功能 '$func'。"
                pause
            fi
        else
            err "无效选项"
            sleep 1
        fi
    done
}

main_menu() {
    local i group choice
    while true; do
        show_banner
        echo -e "${YELLOW}[状态监控]${RESET}"
        declare -f st_status_text >/dev/null && st_status_text
        declare -f gcli_status_text >/dev/null && gcli_status_text
        echo -e "${BLUE}----------------------------------------------${RESET}"

        i=1
        declare -A group_map=()
        for group in "${MAIN_GROUP_ORDER[@]}"; do
            echo -e "  ${GREEN}$i)${RESET} $group"
            group_map[$i]="$group"
            ((i++))
        done
        echo -e "\n${RED}0)${RESET} 退出"
        read -rp "请选择 [0-$((i-1))]: " choice
        if [[ "$choice" == "0" ]]; then
            exit 0
        elif [[ -n "${group_map[$choice]}" ]]; then
            show_group_menu "${group_map[$choice]}"
        else
            err "无效选项"
            sleep 1
        fi
    done
}

load_settings
load_modules
main_menu
