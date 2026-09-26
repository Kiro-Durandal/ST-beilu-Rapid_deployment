#!/usr/bin/env bash

GCLI_DIR="$HOME/gcli2api"
GCLI_REPO="https://github.com/su-kaka/gcli2api.git"
# 旧版管理器的一次性更新桥接标记；实际安装仍只使用下面的新提交。
# GCLI_COMMIT="cdbaf37003a92de31b8a02512d43df3ed6de3411"
GCLI_COMMIT="87f56c8cb088f25c58d947d54424cc889ae7c9aa"
GCLI_WEB_SHA256="27201103ddd0a564d7be2838f9f3ab0c8253f6b048e46c39371991cabbe9246e"
GCLI_REQUIREMENTS_SHA256="c54644f73c84e85263bb0d00630b3c06cef57535631a360756bd485ecffe30d6"
GCLI_FASTAPI_VERSION="0.118.3"
GCLI_PYDANTIC_VERSION="1.10.26"
GCLI_CONFIG_DIR="$HOME/.config/st-manager"
GCLI_ENV_FILE="$GCLI_CONFIG_DIR/gcli2api.env"
GCLI_CREDS_DIR="$GCLI_DIR/creds"
GCLI_PID_FILE="$GCLI_CONFIG_DIR/gcli2api.pid"
GCLI_PM2_NAME="st-manager-gcli2api"
GCLI_LEGACY_PM2_NAME="web"
GCLI_PROXY_SETTINGS_FILE="$GCLI_CONFIG_DIR/gcli2api-lan.conf"
GCLI_PROXY_ROOT="$GCLI_CONFIG_DIR/gcli2api-nginx"
GCLI_PROXY_CONF="$GCLI_PROXY_ROOT/nginx.conf"
GCLI_PROXY_PID_FILE="$GCLI_PROXY_ROOT/logs/nginx.pid"
GCLI_PROXY_ERROR_LOG="$GCLI_PROXY_ROOT/logs/error.log"

get_gcli_version() {
    if [[ -d "$GCLI_DIR/.git" ]]; then
        git -C "$GCLI_DIR" rev-parse --short HEAD 2>/dev/null || echo "未知"
    elif [[ -f "$GCLI_DIR/web.py" ]]; then
        echo "已安装"
    else
        echo "未安装"
    fi
}

gcli_pm2_owned() {
    local name="$1"
    command -v pm2 >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    pm2 jlist 2>/dev/null | jq -e \
        --arg name "$name" \
        --arg dir "$GCLI_DIR" \
        '.[] | select(.name == $name) | select(.pm2_env.pm_cwd == $dir or .pm2_env.pm_exec_path == ($dir + "/web.py") or .pm2_env.pm_exec_path == ($dir + "/.venv/bin/python"))' \
        >/dev/null 2>&1
}

gcli_pm2_running() {
    local name="$1" pid
    gcli_pm2_owned "$name" || return 1
    pid=$(pm2 pid "$name" 2>/dev/null | tail -n 1)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]]
}

gcli_running_pm2_name() {
    if gcli_pm2_running "$GCLI_PM2_NAME"; then
        echo "$GCLI_PM2_NAME"
        return 0
    fi
    if gcli_pm2_running "$GCLI_LEGACY_PM2_NAME"; then
        echo "$GCLI_LEGACY_PM2_NAME"
        return 0
    fi
    return 1
}

gcli_pid_matches() {
    local pid="$1" cwd cmdline
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1
    [[ "$cwd" == "$GCLI_DIR" ]] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ "$cmdline" == *"web.py"* ]]
}

gcli_fallback_pid() {
    local pid
    [[ -f "$GCLI_PID_FILE" ]] || return 1
    read -r pid < "$GCLI_PID_FILE"
    if gcli_pid_matches "$pid"; then
        echo "$pid"
        return 0
    fi
    rm -f -- "$GCLI_PID_FILE"
    return 1
}

is_gcli_running() {
    gcli_running_pm2_name >/dev/null 2>&1 || gcli_fallback_pid >/dev/null 2>&1
}

gcli_status_text() {
    local ver status proxy_status
    ver=$(get_gcli_version)
    if is_gcli_running; then
        status="${GREEN}运行中（后端 127.0.0.1:7861）${RESET}"
    else
        status="${RED}已停止${RESET}"
    fi
    if gcli_proxy_is_running; then
        gcli_proxy_load_settings >/dev/null 2>&1 || true
        proxy_status="${GREEN}LAN ${GCLI_PROXY_BIND_IP}:${GCLI_PROXY_BIND_PORT}${RESET}"
    elif gcli_proxy_load_settings >/dev/null 2>&1 && [[ "$GCLI_PROXY_ENABLED" == "true" ]]; then
        proxy_status="${YELLOW}LAN 共享待启动${RESET}"
    else
        proxy_status="${BLUE}LAN 共享关闭${RESET}"
    fi
    echo -e "gcli2api   : ${GREEN}$ver${RESET} | $status"
    echo -e "LAN API    : $proxy_status"
}

gcli_load_secrets() {
    local key value
    GCLI_API_PASSWORD=""
    GCLI_PANEL_PASSWORD=""
    [[ -f "$GCLI_ENV_FILE" ]] || return 1

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        case "$key" in
            API_PASSWORD) GCLI_API_PASSWORD="$value" ;;
            PANEL_PASSWORD) GCLI_PANEL_PASSWORD="$value" ;;
        esac
    done < "$GCLI_ENV_FILE"

    [[ "$GCLI_API_PASSWORD" =~ ^[0-9a-fA-F]{32,128}$ ]] || return 1
    [[ "$GCLI_PANEL_PASSWORD" =~ ^[0-9a-fA-F]{32,128}$ ]] || return 1
}

gcli_create_secrets() {
    local api_password panel_password
    mkdir -p "$GCLI_CONFIG_DIR"
    chmod 700 "$GCLI_CONFIG_DIR"
    api_password=$(openssl rand -hex 24) || return 1
    panel_password=$(openssl rand -hex 24) || return 1
    {
        printf 'API_PASSWORD=%s\n' "$api_password"
        printf 'PANEL_PASSWORD=%s\n' "$panel_password"
    } > "$GCLI_ENV_FILE"
    chmod 600 "$GCLI_ENV_FILE"
    gcli_load_secrets
}

gcli_ensure_secrets() {
    if gcli_load_secrets; then
        chmod 600 "$GCLI_ENV_FILE" 2>/dev/null || true
        return 0
    fi
    warn "正在生成独立的随机 API 密码和控制面板密码..."
    gcli_create_secrets
}

gcli_proxy_defaults() {
    GCLI_PROXY_ENABLED=false
    GCLI_PROXY_BIND_IP="192.168.0.1"
    GCLI_PROXY_BIND_PORT=7861
    GCLI_PROXY_ALLOW_CIDR="192.168.0.0/24"
}

gcli_proxy_ipv4_to_int() {
    local ip="$1" a b c d extra part
    IFS='.' read -r a b c d extra <<< "$ip"
    [[ -z "$extra" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    for part in "$a" "$b" "$c" "$d"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        [[ "$part" == "0" || "$part" != 0* ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
    printf '%u\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

gcli_proxy_private_ipv4() {
    local ip="$1" a b c d value
    value=$(gcli_proxy_ipv4_to_int "$ip") || return 1
    IFS='.' read -r a b c d <<< "$ip"
    (( a == 10 )) ||
        (( a == 172 && b >= 16 && b <= 31 )) ||
        (( a == 192 && b == 168 ))
}

gcli_proxy_validate_cidr() {
    local cidr="$1" network prefix network_value mask
    [[ "$cidr" == */* ]] || return 1
    network="${cidr%/*}"
    prefix="${cidr#*/}"
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    (( 10#$prefix >= 8 && 10#$prefix <= 32 )) || return 1
    gcli_proxy_private_ipv4 "$network" || return 1
    network_value=$(gcli_proxy_ipv4_to_int "$network") || return 1
    mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    (( (network_value & mask) == network_value ))
}

gcli_proxy_validate_settings() {
    local bind_value network prefix network_value mask
    [[ "$GCLI_PROXY_ENABLED" == "true" || "$GCLI_PROXY_ENABLED" == "false" ]] || return 1
    gcli_proxy_private_ipv4 "$GCLI_PROXY_BIND_IP" || return 1
    [[ "$GCLI_PROXY_BIND_PORT" =~ ^[0-9]{4,5}$ ]] || return 1
    (( 10#$GCLI_PROXY_BIND_PORT >= 1024 && 10#$GCLI_PROXY_BIND_PORT <= 65535 )) || return 1
    gcli_proxy_validate_cidr "$GCLI_PROXY_ALLOW_CIDR" || return 1

    bind_value=$(gcli_proxy_ipv4_to_int "$GCLI_PROXY_BIND_IP") || return 1
    network="${GCLI_PROXY_ALLOW_CIDR%/*}"
    prefix="${GCLI_PROXY_ALLOW_CIDR#*/}"
    network_value=$(gcli_proxy_ipv4_to_int "$network") || return 1
    mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    (( (bind_value & mask) == (network_value & mask) ))
}

gcli_proxy_load_settings() {
    local key value
    gcli_proxy_defaults
    [[ -f "$GCLI_PROXY_SETTINGS_FILE" ]] || return 0

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        case "$key" in
            ENABLED) GCLI_PROXY_ENABLED="$value" ;;
            BIND_IP) GCLI_PROXY_BIND_IP="$value" ;;
            BIND_PORT) GCLI_PROXY_BIND_PORT="$value" ;;
            ALLOW_CIDR) GCLI_PROXY_ALLOW_CIDR="$value" ;;
        esac
    done < "$GCLI_PROXY_SETTINGS_FILE"

    chmod 600 "$GCLI_PROXY_SETTINGS_FILE" 2>/dev/null || true
    gcli_proxy_validate_settings
}

gcli_proxy_save_settings() {
    local temp_file
    gcli_proxy_validate_settings || return 1
    mkdir -p "$GCLI_CONFIG_DIR"
    chmod 700 "$GCLI_CONFIG_DIR"
    temp_file=$(mktemp "$GCLI_CONFIG_DIR/.gcli2api-lan.XXXXXX") || return 1
    {
        printf 'ENABLED=%s\n' "$GCLI_PROXY_ENABLED"
        printf 'BIND_IP=%s\n' "$GCLI_PROXY_BIND_IP"
        printf 'BIND_PORT=%s\n' "$GCLI_PROXY_BIND_PORT"
        printf 'ALLOW_CIDR=%s\n' "$GCLI_PROXY_ALLOW_CIDR"
    } > "$temp_file" || {
        rm -f -- "$temp_file"
        return 1
    }
    chmod 600 "$temp_file"
    mv -f -- "$temp_file" "$GCLI_PROXY_SETTINGS_FILE"
}

gcli_proxy_pid_matches() {
    local pid="$1" cmdline
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ "$cmdline" == *"nginx"* && "$cmdline" == *"$GCLI_PROXY_ROOT"* ]]
}

gcli_proxy_running_pid() {
    local pid
    [[ -f "$GCLI_PROXY_PID_FILE" ]] || return 1
    read -r pid < "$GCLI_PROXY_PID_FILE"
    if gcli_proxy_pid_matches "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi
    rm -f -- "$GCLI_PROXY_PID_FILE"
    return 1
}

gcli_proxy_is_running() {
    gcli_proxy_running_pid >/dev/null 2>&1
}

gcli_proxy_bind_ip_present() {
    local addresses
    command -v ip >/dev/null 2>&1 || return 2
    addresses=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1) || return 2
    [[ -n "$addresses" ]] || return 2
    grep -Fxq -- "$GCLI_PROXY_BIND_IP" <<< "$addresses"
}

gcli_proxy_install_dependencies() {
    local packages=()
    [[ -n "${PREFIX:-}" && "$PREFIX" == *"com.termux"* ]] || return 1
    command -v nginx >/dev/null 2>&1 || packages+=(nginx)
    (( ${#packages[@]} == 0 )) || pkg install -y "${packages[@]}"
}

gcli_proxy_write_nginx_config() {
    local temp_conf
    gcli_proxy_validate_settings || return 1
    mkdir -p "$GCLI_PROXY_ROOT/logs" "$GCLI_PROXY_ROOT/temp"
    chmod 700 "$GCLI_PROXY_ROOT" "$GCLI_PROXY_ROOT/logs" "$GCLI_PROXY_ROOT/temp"
    temp_conf=$(mktemp "$GCLI_PROXY_ROOT/.nginx.conf.XXXXXX") || return 1
    cat > "$temp_conf" <<EOF
worker_processes 1;
pid logs/nginx.pid;
error_log logs/error.log warn;

events {
    worker_connections 64;
}

http {
    access_log off;
    server_tokens off;
    keepalive_timeout 30s;
    client_max_body_size 32m;
    client_body_timeout 300s;
    send_timeout 3600s;
    client_body_temp_path temp/client_body 1 2;
    proxy_temp_path temp/proxy 1 2;

    server {
        listen ${GCLI_PROXY_BIND_IP}:${GCLI_PROXY_BIND_PORT};
        server_name _;

        allow ${GCLI_PROXY_ALLOW_CIDR};
        deny all;

        location ~ ^/(v1|v1beta)/ {
            proxy_pass http://127.0.0.1:7861;
            proxy_http_version 1.1;
            proxy_set_header Host 127.0.0.1:7861;
            proxy_set_header Connection "";
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        location ~ ^/antigravity/(v1|v1beta)/ {
            proxy_pass http://127.0.0.1:7861;
            proxy_http_version 1.1;
            proxy_set_header Host 127.0.0.1:7861;
            proxy_set_header Connection "";
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        location = /keepalive {
            proxy_pass http://127.0.0.1:7861;
            proxy_http_version 1.1;
            proxy_buffering off;
        }

        location / {
            return 403;
        }
    }
}
EOF
    if ! nginx -t -p "$GCLI_PROXY_ROOT/" -c "$temp_conf"; then
        rm -f -- "$temp_conf"
        return 1
    fi
    chmod 600 "$temp_conf"
    mv -f -- "$temp_conf" "$GCLI_PROXY_CONF"
}

gcli_proxy_start_impl() {
    gcli_proxy_load_settings || return 1
    [[ "$GCLI_PROXY_ENABLED" == "true" ]] || return 0
    is_gcli_running || return 1
    command -v nginx >/dev/null 2>&1 || return 1
    gcli_proxy_bind_ip_present || return 1
    gcli_proxy_is_running && return 0
    gcli_proxy_write_nginx_config || return 1
    nginx -p "$GCLI_PROXY_ROOT/" -c "$GCLI_PROXY_CONF" || return 1
    sleep 1
    gcli_proxy_is_running
}

gcli_proxy_start_if_enabled() {
    gcli_proxy_load_settings || {
        warn "LAN API 共享配置无效，未启动 Nginx。"
        return 1
    }
    [[ "$GCLI_PROXY_ENABLED" == "true" ]] || return 0
    if ! gcli_proxy_start_impl; then
        warn "gcli2api 已运行，但 LAN API 共享启动失败。"
        return 1
    fi
}

gcli_proxy_stop_impl() {
    local pid count=0
    pid=$(gcli_proxy_running_pid 2>/dev/null) || return 1
    kill -QUIT "$pid" 2>/dev/null || return 1
    while kill -0 "$pid" 2>/dev/null && (( count < 30 )); do
        sleep 0.1
        ((count++))
    done
    if kill -0 "$pid" 2>/dev/null && gcli_proxy_pid_matches "$pid"; then
        kill -TERM "$pid" 2>/dev/null || return 1
    fi
    count=0
    while kill -0 "$pid" 2>/dev/null && (( count < 20 )); do
        sleep 0.1
        ((count++))
    done
    kill -0 "$pid" 2>/dev/null && return 1
    rm -f -- "$GCLI_PROXY_PID_FILE"
    return 0
}

gcli_proxy_configure() {
    local input new_ip new_port new_cidr
    gcli_proxy_load_settings || {
        err "现有 LAN API 共享配置无效。请删除 $GCLI_PROXY_SETTINGS_FILE 后重试。"
        pause
        return
    }
    if [[ "$GCLI_PROXY_ENABLED" == "true" ]] || gcli_proxy_is_running; then
        warn "请先关闭 LAN API 共享，再修改监听配置。"
        pause
        return
    fi

    read -rp "绑定的私有 IPv4 [$GCLI_PROXY_BIND_IP]: " input || return
    new_ip="${input:-$GCLI_PROXY_BIND_IP}"
    read -rp "监听端口 [$GCLI_PROXY_BIND_PORT]: " input || return
    new_port="${input:-$GCLI_PROXY_BIND_PORT}"
    read -rp "允许访问的私有网段 [$GCLI_PROXY_ALLOW_CIDR]: " input || return
    new_cidr="${input:-$GCLI_PROXY_ALLOW_CIDR}"

    GCLI_PROXY_BIND_IP="$new_ip"
    GCLI_PROXY_BIND_PORT="$new_port"
    GCLI_PROXY_ALLOW_CIDR="$new_cidr"
    if gcli_proxy_save_settings; then
        success "已保存：$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT，允许 $GCLI_PROXY_ALLOW_CIDR。"
    else
        err "配置无效：只接受设备上的私有 IPv4、1024-65535 端口及包含该地址的规范私有 CIDR。"
    fi
    pause
}

gcli_proxy_enable() {
    local confirm bind_check
    if ! gcli_proxy_load_settings; then
        err "LAN API 共享配置无效。"
        pause
        return
    fi
    if gcli_proxy_is_running; then
        success "LAN API 已在 http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT 运行。"
        pause
        return
    fi

    echo -e "${YELLOW}将向 $GCLI_PROXY_ALLOW_CIDR 开放 API 路径，但继续阻止控制面板。${RESET}"
    echo -e "传输仍是 HTTP；请仅在可信局域网使用，并保管好 API 密码。"
    read -rp "确认启用 $GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if ! gcli_proxy_install_dependencies; then
        err "Nginx 安装失败。"
        pause
        return
    fi
    gcli_proxy_bind_ip_present
    bind_check=$?
    case "$bind_check" in
        1)
            err "当前设备没有地址 $GCLI_PROXY_BIND_IP；请检查 ip -br addr 或重新配置。"
            pause
            return
            ;;
        2)
            warn "系统不允许读取接口列表，将由 Nginx 实际绑定结果完成检查。"
            ;;
    esac
    if ! is_gcli_running; then
        log "正在先启动本机 gcli2api 后端..."
        if ! gcli_start_impl; then
            err "gcli2api 后端启动失败，未开放 LAN API。"
            pause
            return
        fi
    fi

    GCLI_PROXY_ENABLED=true
    if ! gcli_proxy_save_settings || ! gcli_proxy_start_impl; then
        GCLI_PROXY_ENABLED=false
        gcli_proxy_save_settings >/dev/null 2>&1 || true
        err "LAN API 共享启动失败；后端仍仅监听 127.0.0.1。"
        [[ -f "$GCLI_PROXY_ERROR_LOG" ]] && tail -n 20 "$GCLI_PROXY_ERROR_LOG"
        pause
        return
    fi
    success "LAN API 已开放：http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT/v1"
    echo -e "控制面板仍只能从 ${GREEN}http://127.0.0.1:7861${RESET} 访问。"
    pause
}

gcli_proxy_disable() {
    gcli_proxy_load_settings >/dev/null 2>&1 || gcli_proxy_defaults
    if gcli_proxy_is_running && ! gcli_proxy_stop_impl; then
        err "无法安全停止属于 ST-Manager 的 Nginx 进程。"
        pause
        return
    fi
    GCLI_PROXY_ENABLED=false
    if gcli_proxy_save_settings; then
        success "LAN API 共享已关闭；127.0.0.1:7861 不受影响。"
    else
        err "无法保存关闭状态。"
    fi
    pause
}

gcli_proxy_logs() {
    if [[ -f "$GCLI_PROXY_ERROR_LOG" ]]; then
        tail -n 60 "$GCLI_PROXY_ERROR_LOG"
    else
        warn "暂无 Nginx 错误日志。"
    fi
    pause
}

gcli_lan_proxy_menu() {
    local choice state
    while true; do
        gcli_proxy_load_settings >/dev/null 2>&1 || gcli_proxy_defaults
        if gcli_proxy_is_running; then
            state="${GREEN}运行中${RESET}"
        elif [[ "$GCLI_PROXY_ENABLED" == "true" ]]; then
            state="${YELLOW}已启用但未运行${RESET}"
        else
            state="${RED}已关闭${RESET}"
        fi
        clear
        echo -e "${BLUE}=== LAN API 共享（Nginx）===${RESET}"
        echo -e "状态: $state"
        echo -e "地址: $GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT"
        echo -e "允许: $GCLI_PROXY_ALLOW_CIDR"
        echo -e "${BLUE}----------------------------------------------${RESET}"
        echo -e "  ${GREEN}1)${RESET} 启用/启动共享"
        echo -e "  ${GREEN}2)${RESET} 关闭共享"
        echo -e "  ${GREEN}3)${RESET} 设置 IP、端口和允许网段"
        echo -e "  ${GREEN}4)${RESET} 查看 Nginx 错误日志"
        echo -e "  ${RED}0)${RESET} 返回"
        read_menu_choice "请选择 [0-4]: " 4 || return
        choice="$REPLY"
        case "$choice" in
            1) gcli_proxy_enable ;;
            2) gcli_proxy_disable ;;
            3) gcli_proxy_configure ;;
            4) gcli_proxy_logs ;;
            0) return ;;
        esac
    done
}

gcli_show_credentials() {
    if ! gcli_ensure_secrets; then
        err "无法读取或生成 gcli2api 密码。"
        pause
        return
    fi
    echo -e "${YELLOW}请勿截图或分享以下密码。${RESET}"
    echo -e "API 地址: ${GREEN}http://127.0.0.1:7861/v1${RESET}"
    echo -e "API 密码: ${GREEN}$GCLI_API_PASSWORD${RESET}"
    echo -e "控制面板: ${GREEN}http://127.0.0.1:7861${RESET}"
    echo -e "面板密码: ${GREEN}$GCLI_PANEL_PASSWORD${RESET}"
    if gcli_proxy_load_settings >/dev/null 2>&1 && [[ "$GCLI_PROXY_ENABLED" == "true" ]]; then
        echo -e "LAN API: ${GREEN}http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT/v1${RESET}"
        echo -e "允许网段: ${GREEN}$GCLI_PROXY_ALLOW_CIDR${RESET}（控制面板未开放）"
    fi
    pause
}

gcli_verify_file() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]]
}

gcli_write_compat_requirements() {
    local input_file="$1" output_file="$2" line package

    : > "$output_file" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        package="${line%%[<>=!~ ]*}"
        case "$package" in
            fastapi|pydantic) continue ;;
        esac
        printf '%s\n' "$line" >> "$output_file" || return 1
    done < "$input_file"

    {
        printf 'fastapi==%s\n' "$GCLI_FASTAPI_VERSION"
        printf 'pydantic==%s\n' "$GCLI_PYDANTIC_VERSION"
    } >> "$output_file"
}

gcli_python_smoke_test() {
    local python_bin="$GCLI_DIR/.venv/bin/python"
    [[ -x "$python_bin" ]] || return 1

    (
        cd "$GCLI_DIR" || exit 1
        GCLI_EXPECT_FASTAPI="$GCLI_FASTAPI_VERSION" \
        GCLI_EXPECT_PYDANTIC="$GCLI_PYDANTIC_VERSION" \
        "$python_bin" - <<'PY'
import os

import fastapi
import pydantic

expected_fastapi = os.environ["GCLI_EXPECT_FASTAPI"]
expected_pydantic = os.environ["GCLI_EXPECT_PYDANTIC"]
if fastapi.__version__ != expected_fastapi:
    raise RuntimeError(
        f"FastAPI version mismatch: {fastapi.__version__} != {expected_fastapi}"
    )
if pydantic.__version__ != expected_pydantic:
    raise RuntimeError(
        f"Pydantic version mismatch: {pydantic.__version__} != {expected_pydantic}"
    )

import web  # noqa: F401,E402
PY
    )
}

gcli_stop_impl() {
    local name pid stopped=false proxy_failed=false
    if gcli_proxy_is_running; then
        if gcli_proxy_stop_impl; then
            stopped=true
        else
            proxy_failed=true
        fi
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        pm2 stop "$name" >/dev/null 2>&1 && stopped=true
    done < <(
        gcli_pm2_running "$GCLI_PM2_NAME" && echo "$GCLI_PM2_NAME"
        gcli_pm2_running "$GCLI_LEGACY_PM2_NAME" && echo "$GCLI_LEGACY_PM2_NAME"
    )

    if pid=$(gcli_fallback_pid 2>/dev/null); then
        kill "$pid" 2>/dev/null || true
        local count=0
        while kill -0 "$pid" 2>/dev/null && (( count < 20 )); do
            sleep 0.1
            ((count++))
        done
        if kill -0 "$pid" 2>/dev/null && gcli_pid_matches "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f -- "$GCLI_PID_FILE"
        stopped=true
    fi
    [[ "$stopped" == "true" && "$proxy_failed" == "false" ]]
}

gcli_install() {
    local packages=() stage_dir source_dir backup_dir="" actual_commit was_running=false
    local compat_requirements
    [[ -n "${HOME:-}" && "$GCLI_DIR" == "$HOME/gcli2api" ]] || {
        err "gcli2api 目录安全检查失败。"
        pause
        return
    }
    if [[ -z "${PREFIX:-}" || "$PREFIX" != *"com.termux"* ]]; then
        err "gcli2api 安装仅支持 Termux。"
        pause
        return
    fi

    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v python >/dev/null 2>&1 || packages+=(python)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl-tool)
    command -v sha256sum >/dev/null 2>&1 || packages+=(coreutils)
    if (( ${#packages[@]} > 0 )) && ! pkg install -y "${packages[@]}"; then
        err "依赖安装失败。"
        pause
        return
    fi

    stage_dir=$(mktemp -d "$HOME/.gcli2api-stage.XXXXXX") || {
        err "无法创建临时目录。"
        pause
        return
    }
    source_dir="$stage_dir/source"

    echo -e "${BLUE}正在获取经过审核并锁定的 gcli2api 提交...${RESET}"
    if ! git init -q "$source_dir" ||
       ! git -C "$source_dir" remote add origin "$GCLI_REPO" ||
       ! git -C "$source_dir" fetch --depth 1 origin "$GCLI_COMMIT" ||
       ! git -C "$source_dir" checkout --detach FETCH_HEAD; then
        rm -rf -- "$stage_dir"
        err "gcli2api 下载失败；当前安装未改动。"
        pause
        return
    fi

    actual_commit=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)
    if [[ "$actual_commit" != "$GCLI_COMMIT" ]] ||
       ! gcli_verify_file "$source_dir/web.py" "$GCLI_WEB_SHA256" ||
       ! gcli_verify_file "$source_dir/requirements-termux.txt" "$GCLI_REQUIREMENTS_SHA256"; then
        rm -rf -- "$stage_dir"
        err "提交或 SHA-256 校验失败；拒绝安装。"
        pause
        return
    fi

    is_gcli_running && was_running=true
    gcli_stop_impl >/dev/null 2>&1 || true
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"

    if [[ -d "$GCLI_DIR" ]]; then
        backup_dir="$BACKUP_ROOT/gcli2api-$(date +%Y%m%d_%H%M%S)-$$"
        log "备份现有 gcli2api 到 $backup_dir"
        if ! mv "$GCLI_DIR" "$backup_dir"; then
            rm -rf -- "$stage_dir"
            err "无法创建备份；已取消安装。"
            pause
            return
        fi
    fi

    if ! mv "$source_dir" "$GCLI_DIR"; then
        [[ -n "$backup_dir" && -d "$backup_dir" ]] && mv "$backup_dir" "$GCLI_DIR"
        rm -rf -- "$stage_dir"
        err "安装文件替换失败，已恢复旧版本。"
        pause
        return
    fi

    if [[ -n "$backup_dir" && -d "$backup_dir/creds" ]]; then
        cp -a "$backup_dir/creds" "$GCLI_CREDS_DIR"
    fi
    mkdir -p "$GCLI_CREDS_DIR"
    chmod 700 "$GCLI_CREDS_DIR"

    echo -e "${BLUE}正在创建隔离的 Python 环境并安装依赖...${RESET}"
    compat_requirements="$GCLI_DIR/requirements-termux-st-manager.txt"
    if ! python -m venv "$GCLI_DIR/.venv" ||
       ! gcli_write_compat_requirements \
            "$GCLI_DIR/requirements-termux.txt" "$compat_requirements" ||
       ! "$GCLI_DIR/.venv/bin/python" -m pip install -r "$compat_requirements" ||
       ! "$GCLI_DIR/.venv/bin/python" -m pip check ||
       ! gcli_python_smoke_test; then
        rm -rf -- "$GCLI_DIR"
        if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
            mv "$backup_dir" "$GCLI_DIR"
        fi
        rm -rf -- "$stage_dir"
        err "Python 依赖安装失败，已恢复旧版本。"
        pause
        return
    fi
    rm -rf -- "$stage_dir"

    if ! gcli_ensure_secrets; then
        err "随机密码生成失败；服务未启动。"
        pause
        return
    fi

    success "gcli2api 已安装为审核过的固定提交 ${GCLI_COMMIT:0:12}。"
    echo -e "${GREEN}Termux 兼容依赖: FastAPI $GCLI_FASTAPI_VERSION / Pydantic $GCLI_PYDANTIC_VERSION。${RESET}"
    echo -e "${GREEN}监听地址已强制设为 127.0.0.1，默认 pwd 已禁用。${RESET}"
    if [[ "$was_running" == "true" ]]; then
        gcli_start_impl || warn "更新完成，但自动重启失败。"
    fi
    gcli_show_credentials
}

gcli_start_impl() {
    local python_bin="$GCLI_DIR/.venv/bin/python" pid
    [[ -x "$python_bin" && -f "$GCLI_DIR/web.py" ]] || return 1
    gcli_python_smoke_test >/dev/null 2>&1 || return 1
    gcli_ensure_secrets || return 1

    if is_gcli_running; then
        gcli_proxy_start_if_enabled || true
        return 0
    fi

    mkdir -p "$GCLI_CONFIG_DIR" "$GCLI_CREDS_DIR"
    chmod 700 "$GCLI_CONFIG_DIR" "$GCLI_CREDS_DIR"

    if command -v pm2 >/dev/null 2>&1; then
        if gcli_pm2_owned "$GCLI_PM2_NAME"; then
            env HOST=127.0.0.1 PORT=7861 \
                "API_PASSWORD=$GCLI_API_PASSWORD" \
                "PANEL_PASSWORD=$GCLI_PANEL_PASSWORD" \
                "CREDENTIALS_DIR=$GCLI_CREDS_DIR" \
                pm2 restart "$GCLI_PM2_NAME" --update-env >/dev/null || return 1
        else
            env HOST=127.0.0.1 PORT=7861 \
                "API_PASSWORD=$GCLI_API_PASSWORD" \
                "PANEL_PASSWORD=$GCLI_PANEL_PASSWORD" \
                "CREDENTIALS_DIR=$GCLI_CREDS_DIR" \
                pm2 start "$python_bin" --name "$GCLI_PM2_NAME" --cwd "$GCLI_DIR" -- web.py >/dev/null || return 1
        fi
    else
        (
            cd "$GCLI_DIR" || exit 1
            exec nohup env HOST=127.0.0.1 PORT=7861 \
                "API_PASSWORD=$GCLI_API_PASSWORD" \
                "PANEL_PASSWORD=$GCLI_PANEL_PASSWORD" \
                "CREDENTIALS_DIR=$GCLI_CREDS_DIR" \
                "$python_bin" web.py
        ) >> "$GCLI_DIR/gcli.log" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$GCLI_PID_FILE"
        chmod 600 "$GCLI_PID_FILE"
    fi

    sleep 3
    is_gcli_running || return 1
    gcli_proxy_start_if_enabled || true
    return 0
}

gcli_start() {
    if [[ ! -f "$GCLI_DIR/web.py" ]]; then
        warn "未检测到 gcli2api，请先安装。"
    elif is_gcli_running; then
        gcli_proxy_start_if_enabled || true
        warn "gcli2api 已经在运行。"
    elif gcli_start_impl; then
        success "启动成功；服务仅监听 127.0.0.1:7861。"
        echo -e "API 地址: ${GREEN}http://127.0.0.1:7861/v1${RESET}"
    else
        err "启动失败，请查看日志。"
    fi
    pause
}

gcli_stop() {
    if gcli_stop_impl; then
        success "已停止 ST-Manager 管理的 gcli2api 进程。"
    else
        warn "未发现属于此安装目录的 gcli2api 进程。"
    fi
    pause
}

gcli_logs() {
    local name log_file="$GCLI_DIR/gcli.log"
    if name=$(gcli_running_pm2_name 2>/dev/null); then
        pm2 logs "$name" --lines 50 --nostream
    elif [[ -f "$log_file" ]]; then
        tail -n 50 "$log_file"
    else
        warn "暂无日志。"
    fi
    pause
}
