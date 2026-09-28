#!/usr/bin/env bash

# ==============================================================================
# Project: ST-Manager (security-hardened fork)
# ==============================================================================

set -o pipefail
umask 077

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_DIR="$DIR"
CONF_DIR="$DIR/conf"
MODULES_DIR="$DIR/modules"
SETTINGS_FILE="$CONF_DIR/settings.conf"
UPDATE_REPO_URL="https://github.com/Kiro-Durandal/ST-beilu-Rapid_deployment.git"
UPDATE_REPO_REF="main"
BACKUP_ROOT="$HOME/ST-Manager-backups"
ST_MANAGER_STATE_DIR="$HOME/.config/st-manager"
AUTOSTART_CONFIG_FILE="$ST_MANAGER_STATE_DIR/autostart.conf"
AUTOSTART_BOOT_DIR="$HOME/.termux/boot"
AUTOSTART_BOOT_SCRIPT="$AUTOSTART_BOOT_DIR/20-st-manager"
AUTOSTART_LOG_FILE="$ST_MANAGER_STATE_DIR/boot.log"
ST_MANAGER_SECURITY_PROFILE="termux-loopback-secrets-v1"
RELEASE_VALIDATION_ERROR=""

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

read_menu_choice() {
    local prompt="$1" max="$2" input
    REPLY=""

    if (( max > 9 )); then
        read -rp "$prompt" REPLY
        return
    fi

    while true; do
        IFS= read -rsn1 -p "$prompt" input || return 1
        printf '%s\n' "$input"
        if [[ "$input" =~ ^[0-9]$ ]] && (( 10#$input <= max )); then
            REPLY="$input"
            return 0
        fi
        warn "请输入 0-$max 之间的数字。"
    done
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
                if [[ -z "${MODULE_GROUP_ORDER[$current_group]:-}" ]]; then
                    MODULE_GROUP_ORDER["$current_group"]="$key"
                else
                    MODULE_GROUP_ORDER["$current_group"]="${MODULE_GROUP_ORDER[$current_group]} $key"
                fi
            fi
        done < "$menu_file"
    done

    sys_group="系统管理"
    local sys_items=("fix_env:修复运行环境" "update_self:更新管理工具" "settings_menu:系统设置" "autostart_menu:开机自启动" "visit_github:访问 GitHub" "visit_discord:加入 Discord 粉丝群")
    for item in "${sys_items[@]}"; do
        key="${item%:*}"
        text="${item#*:}"
        MENU_TEXTS["$key"]="$text"
        FUNCTION_MAP["$key"]="$key"
    done
    MODULE_GROUP_ORDER["$sys_group"]="fix_env update_self settings_menu autostart_menu visit_github visit_discord"
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
    local core_file="$root/core.sh"
    local gcli_file="$root/modules/gcli2api/functions.sh"
    RELEASE_VALIDATION_ERROR=""

    if [[ ! -f "$core_file" || ! -f "$gcli_file" ]]; then
        RELEASE_VALIDATION_ERROR="缺少 core.sh 或 gcli2api 模块"
        return 1
    fi
    if ! grep -Fqx "ST_MANAGER_SECURITY_PROFILE=\"$ST_MANAGER_SECURITY_PROFILE\"" "$core_file"; then
        RELEASE_VALIDATION_ERROR="安全基线标识缺失或不受支持"
        return 1
    fi
    if ! grep -Fqx 'GCLI_REPO="https://github.com/su-kaka/gcli2api.git"' "$gcli_file" ||
       ! grep -Eq '^GCLI_COMMIT="[0-9a-f]{40}"$' "$gcli_file"; then
        RELEASE_VALIDATION_ERROR="gcli2api 来源或提交锁定格式无效"
        return 1
    fi
    if ! grep -Eq '^GCLI_WEB_SHA256="[0-9a-f]{64}"$' "$gcli_file" ||
       ! grep -Eq '^GCLI_REQUIREMENTS_SHA256="[0-9a-f]{64}"$' "$gcli_file"; then
        RELEASE_VALIDATION_ERROR="gcli2api 文件哈希约束缺失"
        return 1
    fi
    if ! grep -Eq '^GCLI_FASTAPI_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$gcli_file" ||
       ! grep -Eq '^GCLI_PYDANTIC_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$gcli_file" ||
       ! grep -Fq 'gcli_python_smoke_test' "$gcli_file"; then
        RELEASE_VALIDATION_ERROR="Termux Python 兼容约束缺失"
        return 1
    fi
    if ! grep -Fq 'env HOST=127.0.0.1 PORT=7861' "$gcli_file" ||
       ! grep -Fq 'openssl rand -hex 24' "$gcli_file" ||
       ! grep -Fq 'Do not source this file' "$core_file"; then
        RELEASE_VALIDATION_ERROR="监听地址、随机密码或配置解析约束缺失"
        return 1
    fi

    return 0
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
    if [[ ! -d "$source_dir" ]]; then
        rm -rf -- "$update_tmp"
        err "更新包结构检查失败：缺少 ST-Manager 目录；当前版本未改动。"
        pause
        return
    fi
    if ! validate_script_tree "$source_dir"; then
        rm -rf -- "$update_tmp"
        err "更新包 Shell 语法检查失败；当前版本未改动。"
        pause
        return
    fi
    if ! validate_hardened_release "$source_dir"; then
        rm -rf -- "$update_tmp"
        err "更新包安全约束检查失败：$RELEASE_VALIDATION_ERROR；当前版本未改动。"
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
        read_menu_choice "请选择 [0-2]: " 2 || return
        choice="$REPLY"
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

# ============================================================================== 
# Termux:Boot autostart
# ============================================================================== 
autostart_defaults() {
    AUTOSTART_MODE="gcli"
}

autostart_load_config() {
    local key value
    autostart_defaults
    [[ -f "$AUTOSTART_CONFIG_FILE" ]] || return 0

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        case "$key" in
            MODE)
                case "$value" in
                    gcli|st|both) AUTOSTART_MODE="$value" ;;
                esac
                ;;
        esac
    done < "$AUTOSTART_CONFIG_FILE"
    chmod 600 "$AUTOSTART_CONFIG_FILE" 2>/dev/null || true
}

autostart_save_config() {
    local temp_file
    case "$AUTOSTART_MODE" in
        gcli|st|both) ;;
        *) return 1 ;;
    esac
    mkdir -p "$ST_MANAGER_STATE_DIR"
    chmod 700 "$ST_MANAGER_STATE_DIR"
    temp_file=$(mktemp "$ST_MANAGER_STATE_DIR/.autostart.XXXXXX") || return 1
    printf 'MODE=%s\n' "$AUTOSTART_MODE" > "$temp_file"
    chmod 600 "$temp_file"
    mv -f -- "$temp_file" "$AUTOSTART_CONFIG_FILE"
}

autostart_mode_text() {
    case "$AUTOSTART_MODE" in
        gcli) printf '仅 gcli2api' ;;
        st) printf '仅 SillyTavern' ;;
        both) printf 'SillyTavern + gcli2api' ;;
        *) printf '未知' ;;
    esac
}

autostart_script_owned() {
    [[ -f "$AUTOSTART_BOOT_SCRIPT" ]] || return 1
    grep -Fqx '# Managed by ST-Manager; do not edit this file manually.' \
        "$AUTOSTART_BOOT_SCRIPT" 2>/dev/null
}

autostart_termux_boot_installed() {
    /system/bin/pm list packages com.termux.boot 2>/dev/null | \
        grep -Fqx 'package:com.termux.boot'
}

autostart_write_boot_script() {
    local temp_file
    if [[ -e "$AUTOSTART_BOOT_SCRIPT" ]] && ! autostart_script_owned; then
        err "$AUTOSTART_BOOT_SCRIPT 已存在且不属于 ST-Manager；拒绝覆盖。"
        return 1
    fi

    mkdir -p "$AUTOSTART_BOOT_DIR" "$ST_MANAGER_STATE_DIR"
    chmod 700 "$AUTOSTART_BOOT_DIR" "$ST_MANAGER_STATE_DIR"
    temp_file=$(mktemp "$AUTOSTART_BOOT_DIR/.20-st-manager.XXXXXX") || return 1
    cat > "$temp_file" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Managed by ST-Manager; do not edit this file manually.

umask 077
export HOME=/data/data/com.termux/files/home
export PREFIX=/data/data/com.termux/files/usr
export PATH="$PREFIX/bin:$PREFIX/bin/applets"

STATE_DIR="$HOME/.config/st-manager"
LOG_FILE="$STATE_DIR/boot.log"
CORE_FILE="$HOME/ST-Manager/core.sh"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec >> "$LOG_FILE" 2>&1

printf '\n[%s] Termux:Boot 正在启动 ST-Manager 服务\n' "$(date '+%F %T')"
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true

# Give Android and the F50 LAN interface time to finish booting.
sleep 30

if [[ ! -f "$CORE_FILE" ]]; then
    printf '[ERROR] 找不到 %s\n' "$CORE_FILE" >&2
    exit 1
fi

exec bash "$CORE_FILE" --boot-start
EOF
    chmod 700 "$temp_file"
    mv -f -- "$temp_file" "$AUTOSTART_BOOT_SCRIPT"
}

autostart_enable() {
    autostart_load_config
    autostart_save_config || {
        err "无法保存开机自启动配置。"
        pause
        return
    }
    if ! autostart_write_boot_script; then
        pause
        return
    fi

    success "开机自启动已启用：$(autostart_mode_text)。"
    if ! autostart_termux_boot_installed; then
        warn "未检测到 Termux:Boot。请安装与当前 Termux 同来源的版本，并手动打开一次。"
    else
        echo -e "请确认 Termux 与 Termux:Boot 均允许开机启动和后台运行。"
    fi
    if [[ "$AUTOSTART_MODE" == "gcli" || "$AUTOSTART_MODE" == "both" ]]; then
        echo -e "gcli2api 启动后，Nginx 将继续服从 LAN 共享中的 [跟随启动] 开关。"
    fi
    pause
}

autostart_disable() {
    if [[ ! -e "$AUTOSTART_BOOT_SCRIPT" ]]; then
        warn "开机自启动当前未启用。"
    elif ! autostart_script_owned; then
        err "$AUTOSTART_BOOT_SCRIPT 不属于 ST-Manager；未删除。"
    elif rm -f -- "$AUTOSTART_BOOT_SCRIPT"; then
        success "已关闭 ST-Manager 开机自启动；配置与日志仍保留。"
    else
        err "无法删除开机启动脚本。"
    fi
    pause
}

autostart_choose_mode() {
    local choice
    autostart_load_config
    clear
    echo -e "${BLUE}=== 选择开机启动组件 ===${RESET}"
    echo -e "1) 仅启动 gcli2api"
    echo -e "2) 仅启动 SillyTavern"
    echo -e "3) 同时启动 SillyTavern 与 gcli2api"
    echo -e "0) 返回"
    read_menu_choice "请选择 [0-3]: " 3 || return
    choice="$REPLY"
    case "$choice" in
        1) AUTOSTART_MODE="gcli" ;;
        2) AUTOSTART_MODE="st" ;;
        3) AUTOSTART_MODE="both" ;;
        0) return ;;
    esac
    if autostart_save_config; then
        success "开机启动组件已设为：$(autostart_mode_text)。"
        autostart_script_owned && echo -e "下次开机自动生效。"
    else
        err "无法保存开机启动组件设置。"
    fi
    pause
}

autostart_show_log() {
    if [[ -f "$AUTOSTART_LOG_FILE" ]]; then
        tail -n 80 "$AUTOSTART_LOG_FILE"
    else
        warn "暂无开机启动日志。"
    fi
    pause
}

autostart_test_now() {
    local confirm
    autostart_load_config
    echo -e "将立即按 [$(autostart_mode_text)] 执行一次非交互启动。"
    read -rp "继续？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
    if boot_start_services; then
        success "测试启动完成。"
    else
        err "测试启动存在失败项，请查看上方输出。"
    fi
    pause
}

autostart_menu() {
    local choice enabled boot_status
    while true; do
        autostart_load_config
        if autostart_script_owned; then
            enabled="${GREEN}已启用${RESET}"
        elif [[ -e "$AUTOSTART_BOOT_SCRIPT" ]]; then
            enabled="${YELLOW}存在非 ST-Manager 脚本${RESET}"
        else
            enabled="${RED}未启用${RESET}"
        fi
        if autostart_termux_boot_installed; then
            boot_status="${GREEN}已安装${RESET}"
        else
            boot_status="${YELLOW}未检测到${RESET}"
        fi

        clear
        echo -e "${BLUE}=== 开机自启动（Termux:Boot）===${RESET}"
        echo -e "状态: $enabled"
        echo -e "组件: $(autostart_mode_text)"
        echo -e "Termux:Boot: $boot_status"
        echo -e "${BLUE}----------------------------------------------${RESET}"
        echo -e "1) 启用/刷新开机启动脚本"
        echo -e "2) 选择启动组件"
        echo -e "3) 关闭开机自启动"
        echo -e "4) 立即测试启动"
        echo -e "5) 查看开机启动日志"
        echo -e "0) 返回"
        read_menu_choice "请选择 [0-5]: " 5 || return
        choice="$REPLY"
        case "$choice" in
            1) autostart_enable ;;
            2) autostart_choose_mode ;;
            3) autostart_disable ;;
            4) autostart_test_now ;;
            5) autostart_show_log ;;
            0) return ;;
        esac
    done
}

boot_start_gcli() {
    local retry_needed=false
    if [[ ! -f "$GCLI_DIR/web.py" ]]; then
        err "gcli2api 尚未安装。"
        return 1
    fi
    if ! gcli_start_impl; then
        err "gcli2api 启动失败。"
        return 1
    fi
    success "gcli2api 已启动。"

    if ! gcli_proxy_load_settings; then
        err "LAN 共享配置无效；Nginx 未启动。"
        return 1
    fi
    if [[ "$GCLI_PROXY_AUTO_START" != "true" ]]; then
        log "LAN 共享的跟随启动开关为关闭，未启动 Nginx。"
        return 0
    fi
    if ! gcli_proxy_is_running; then
        retry_needed=true
        warn "Nginx 尚未运行；等待 LAN 接口后重试一次。"
        sleep 10
        gcli_proxy_start_if_enabled || true
    fi
    if gcli_proxy_is_running; then
        if [[ "$retry_needed" == "true" ]]; then
            success "Nginx LAN 共享重试启动成功。"
        else
            success "Nginx LAN 共享已随 gcli2api 启动。"
        fi
        return 0
    fi
    err "已要求 Nginx 跟随启动，但启动或验证失败。"
    [[ -f "$GCLI_PROXY_ERROR_LOG" ]] && tail -n 30 "$GCLI_PROXY_ERROR_LOG"
    return 1
}

boot_start_st() {
    if [[ ! -f "$ST_DIR/server.js" ]]; then
        err "SillyTavern 尚未安装。"
        return 1
    fi
    if is_st_running || st_start_impl; then
        success "SillyTavern 已启动。"
        return 0
    fi
    err "SillyTavern 启动失败。"
    return 1
}

boot_start_services() {
    local failures=0
    autostart_load_config
    log "开机启动组合：$(autostart_mode_text)。"

    case "$AUTOSTART_MODE" in
        gcli)
            boot_start_gcli || ((failures++))
            ;;
        st)
            boot_start_st || ((failures++))
            ;;
        both)
            boot_start_gcli || ((failures++))
            boot_start_st || ((failures++))
            ;;
        *)
            err "未知开机启动模式：$AUTOSTART_MODE"
            return 1
            ;;
    esac

    if (( failures == 0 )); then
        success "开机启动任务完成。"
        return 0
    fi
    err "开机启动任务完成，但有 $failures 个失败项。"
    return 1
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

start_all_services() {
    local failures=0
    clear
    echo -e "${BLUE}=== 一键启动全部组件 ===${RESET}"

    echo -e "${BLUE}正在启动 gcli2api...${RESET}"
    if [[ ! -f "$GCLI_DIR/web.py" ]]; then
        err "gcli2api 尚未安装。"
        ((failures++))
    elif is_gcli_running; then
        if gcli_proxy_start_if_enabled; then
            success "gcli2api 已在运行。"
        else
            err "gcli2api 已运行，但 LAN API 共享启动失败。"
            ((failures++))
        fi
    elif gcli_start_impl; then
        success "gcli2api 启动成功。"
    else
        err "gcli2api 启动失败，请查看其日志。"
        ((failures++))
    fi

    echo -e "${BLUE}正在启动 SillyTavern...${RESET}"
    if [[ ! -f "$ST_DIR/server.js" ]]; then
        err "SillyTavern 尚未安装。"
        ((failures++))
    elif is_st_running; then
        success "SillyTavern 已在运行。"
    elif st_start_impl; then
        success "SillyTavern 启动成功。"
    else
        err "SillyTavern 启动失败，请查看其日志。"
        ((failures++))
    fi

    if (( failures == 0 )); then
        success "两个组件均已启动。"
    else
        warn "启动完成，但有 $failures 个组件未成功启动。"
    fi
    pause
}

stop_all_services() {
    local failures=0
    clear
    echo -e "${BLUE}=== 一键停止全部组件 ===${RESET}"

    echo -e "${BLUE}正在停止 SillyTavern...${RESET}"
    if ! is_st_running; then
        log "SillyTavern 已经停止。"
    elif st_stop_impl; then
        success "SillyTavern 已停止。"
    else
        err "SillyTavern 停止失败。"
        ((failures++))
    fi

    echo -e "${BLUE}正在停止 gcli2api...${RESET}"
    if ! is_gcli_running && ! gcli_proxy_is_running; then
        log "gcli2api 已经停止。"
    elif gcli_stop_impl; then
        success "gcli2api 已停止。"
    else
        err "gcli2api 停止失败。"
        ((failures++))
    fi

    if (( failures == 0 )); then
        success "两个组件均已停止。"
    else
        warn "停止完成，但有 $failures 个组件未成功停止。"
    fi
    pause
}

# ==============================================================================
# Menus
# ==============================================================================
show_banner() {
    clear
    echo -e "${BLUE}==============================================${RESET}"
    echo -e "${GREEN}        与你之歌 v1.6（安全加固版）       ${RESET}"
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
        if [[ -n "${MODULE_GROUP_ORDER[$group_name]:-}" ]]; then
            for key in ${MODULE_GROUP_ORDER[$group_name]}; do
                echo -e "  ${GREEN}$i)${RESET} ${MENU_TEXTS[$key]}"
                active_options[$i]="$key"
                ((i++))
            done
        fi

        echo -e "\n${RED}0)${RESET} 返回上一级"
        read_menu_choice "请选择 [0-$((i-1))]: " "$((i-1))" || return
        choice="$REPLY"
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
    local i group choice action
    while true; do
        show_banner
        echo -e "${YELLOW}[状态监控]${RESET}"
        declare -f st_status_text >/dev/null && st_status_text
        declare -f gcli_status_text >/dev/null && gcli_status_text
        echo -e "${BLUE}----------------------------------------------${RESET}"

        i=1
        declare -A group_map=()
        declare -A action_map=()
        for group in "${MAIN_GROUP_ORDER[@]}"; do
            echo -e "  ${GREEN}$i)${RESET} $group"
            group_map[$i]="$group"
            ((i++))
        done
        echo -e "  ${GREEN}$i)${RESET} 一键启动全部组件"
        action_map[$i]="start_all_services"
        ((i++))
        echo -e "  ${GREEN}$i)${RESET} 一键停止全部组件"
        action_map[$i]="stop_all_services"
        ((i++))
        echo -e "\n${RED}0)${RESET} 退出"
        read_menu_choice "请选择 [0-$((i-1))]: " "$((i-1))" || exit 0
        choice="$REPLY"
        if [[ "$choice" == "0" ]]; then
            exit 0
        elif [[ -n "${group_map[$choice]}" ]]; then
            show_group_menu "${group_map[$choice]}"
        elif [[ -n "${action_map[$choice]}" ]]; then
            action="${action_map[$choice]}"
            "$action"
        else
            err "无效选项"
            sleep 1
        fi
    done
}

main() {
    load_settings
    load_modules
    case "${1:-}" in
        --boot-start) boot_start_services ;;
        "") main_menu ;;
        *)
            err "未知参数：$1"
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
