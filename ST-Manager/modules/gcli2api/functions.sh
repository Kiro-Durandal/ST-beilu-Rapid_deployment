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
    local ver status proxy_status mode_text auto_text
    ver=$(get_gcli_version)
    if is_gcli_running; then
        status="${GREEN}运行中（后端 127.0.0.1:7861）${RESET}"
    else
        status="${RED}已停止${RESET}"
    fi
    gcli_proxy_load_settings >/dev/null 2>&1 || gcli_proxy_defaults
    mode_text=$(gcli_proxy_mode_text)
    if [[ "$GCLI_PROXY_AUTO_START" == "true" ]]; then
        auto_text="自动启动：开"
    else
        auto_text="自动启动：关"
    fi
    if gcli_proxy_is_running; then
        proxy_status="${GREEN}${GCLI_PROXY_BIND_IP}:${GCLI_PROXY_BIND_PORT}（$mode_text，$auto_text）${RESET}"
    elif [[ "$GCLI_PROXY_AUTO_START" == "true" ]]; then
        proxy_status="${YELLOW}已停止（$mode_text，$auto_text）${RESET}"
    else
        proxy_status="${BLUE}已停止（$mode_text，$auto_text）${RESET}"
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

gcli_password_store() {
    local action="$1" status
    local python_bin="$GCLI_DIR/.venv/bin/python"
    [[ -x "$python_bin" ]] || return 1
    mkdir -p "$GCLI_CREDS_DIR"
    chmod 700 "$GCLI_CREDS_DIR"

    (
        # Password environment variables make these fields read-only in the
        # upstream control panel. Keep them out of both this helper and the
        # long-running server process.
        unset API_PASSWORD PANEL_PASSWORD PASSWORD
        env \
            "GCLI_PASSWORD_DB=$GCLI_CREDS_DIR/credentials.db" \
            "GCLI_INITIAL_API_PASSWORD=$GCLI_API_PASSWORD" \
            "GCLI_INITIAL_PANEL_PASSWORD=$GCLI_PANEL_PASSWORD" \
            "$python_bin" - "$action" <<'PY'
import base64
import json
import os
import sqlite3
import sys


def as_text(raw):
    if raw is None:
        return ""
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        value = raw
    return value if isinstance(value, str) else str(value)


action = sys.argv[1]
database = os.environ["GCLI_PASSWORD_DB"]
connection = sqlite3.connect(database, timeout=10)
try:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS config (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL DEFAULT (unixepoch())
        )
        """
    )

    if action == "ensure":
        initial_values = {
            "api_password": os.environ["GCLI_INITIAL_API_PASSWORD"],
            "panel_password": os.environ["GCLI_INITIAL_PANEL_PASSWORD"],
        }
        for key, value in initial_values.items():
            connection.execute(
                """
                INSERT OR IGNORE INTO config (key, value, updated_at)
                VALUES (?, ?, unixepoch())
                """,
                (key, json.dumps(value)),
            )
        connection.commit()
    elif action == "read":
        encoded_values = []
        for key in ("api_password", "panel_password"):
            row = connection.execute(
                "SELECT value FROM config WHERE key = ?", (key,)
            ).fetchone()
            value = as_text(row[0]) if row else ""
            encoded_values.append(
                base64.b64encode(value.encode("utf-8")).decode("ascii")
            )
        print(":".join(encoded_values))
    else:
        raise SystemExit(f"unsupported password-store action: {action}")
finally:
    connection.close()
PY
    )
    status=$?
    [[ -f "$GCLI_CREDS_DIR/credentials.db" ]] && \
        chmod 600 "$GCLI_CREDS_DIR/credentials.db" 2>/dev/null || true
    return "$status"
}

gcli_ensure_stored_passwords() {
    gcli_ensure_secrets || return 1
    gcli_password_store ensure
}

gcli_read_stored_passwords() {
    local api_encoded panel_encoded output
    gcli_ensure_stored_passwords || return 1
    output=$(gcli_password_store read) || return 1
    [[ "$output" == *:* ]] || return 1
    IFS=: read -r api_encoded panel_encoded <<< "$output"

    GCLI_API_PASSWORD=$(printf '%s' "$api_encoded" | base64 -d) || return 1
    GCLI_PANEL_PASSWORD=$(printf '%s' "$panel_encoded" | base64 -d) || return 1
}

gcli_proxy_defaults() {
    GCLI_PROXY_MODE="api"
    GCLI_PROXY_AUTO_START=false
    GCLI_PROXY_BIND_IP="192.168.0.1"
    GCLI_PROXY_BIND_PORT=7861
    GCLI_PROXY_ALLOW_CIDR="192.168.0.0/24"
}

gcli_proxy_mode_text() {
    case "$GCLI_PROXY_MODE" in
        api) printf '仅 API' ;;
        full) printf '完整转发' ;;
        *) printf '未知' ;;
    esac
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
    [[ "$GCLI_PROXY_MODE" == "api" || "$GCLI_PROXY_MODE" == "full" ]] || return 1
    [[ "$GCLI_PROXY_AUTO_START" == "true" || "$GCLI_PROXY_AUTO_START" == "false" ]] || return 1
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
    local key value legacy_enabled="" auto_start_seen=false
    gcli_proxy_defaults
    [[ -f "$GCLI_PROXY_SETTINGS_FILE" ]] || return 0

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        case "$key" in
            ENABLED) legacy_enabled="$value" ;;
            MODE) GCLI_PROXY_MODE="$value" ;;
            AUTO_START)
                GCLI_PROXY_AUTO_START="$value"
                auto_start_seen=true
                ;;
            BIND_IP) GCLI_PROXY_BIND_IP="$value" ;;
            BIND_PORT) GCLI_PROXY_BIND_PORT="$value" ;;
            ALLOW_CIDR) GCLI_PROXY_ALLOW_CIDR="$value" ;;
        esac
    done < "$GCLI_PROXY_SETTINGS_FILE"

    # v1.4 used ENABLED as both running intent and automatic startup. Preserve
    # that behavior once, while new configurations keep those states separate.
    if [[ "$auto_start_seen" == "false" &&
          ( "$legacy_enabled" == "true" || "$legacy_enabled" == "false" ) ]]; then
        GCLI_PROXY_AUTO_START="$legacy_enabled"
    fi

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
        # ENABLED remains as a rollback-compatible alias for v1.4.
        printf 'ENABLED=%s\n' "$GCLI_PROXY_AUTO_START"
        printf 'MODE=%s\n' "$GCLI_PROXY_MODE"
        printf 'AUTO_START=%s\n' "$GCLI_PROXY_AUTO_START"
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

gcli_proxy_log_diagnostic() {
    mkdir -p "$GCLI_PROXY_ROOT/logs" 2>/dev/null || return 0
    printf '[%s] [st-manager] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$GCLI_PROXY_ERROR_LOG" 2>/dev/null || true
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
EOF
    if [[ "$GCLI_PROXY_MODE" == "full" ]]; then
        cat >> "$temp_conf" <<EOF
        # Full forwarding exposes the authenticated control panel and
        # credential-management routes to the configured client CIDR.
        location / {
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
EOF
    else
        cat >> "$temp_conf" <<'EOF'
        # API-only mode blocks the control panel, credentials, logs and assets.
        location / {
            return 403;
        }
EOF
    fi
    cat >> "$temp_conf" <<'EOF'
    }
}
EOF
    if ! nginx -t -p "$GCLI_PROXY_ROOT/" -c "$temp_conf" \
        2>> "$GCLI_PROXY_ERROR_LOG"; then
        rm -f -- "$temp_conf"
        return 1
    fi
    chmod 600 "$temp_conf"
    mv -f -- "$temp_conf" "$GCLI_PROXY_CONF"
}

gcli_proxy_start_impl() {
    local bind_check
    if ! gcli_proxy_load_settings; then
        gcli_proxy_log_diagnostic "LAN API 共享配置无效。"
        return 1
    fi
    if ! is_gcli_running; then
        gcli_proxy_log_diagnostic "gcli2api 后端未运行。"
        return 1
    fi
    if ! command -v nginx >/dev/null 2>&1; then
        gcli_proxy_log_diagnostic "未找到 nginx 命令。"
        return 1
    fi
    if gcli_proxy_bind_ip_present; then
        :
    else
        bind_check=$?
        case "$bind_check" in
            1)
                gcli_proxy_log_diagnostic \
                    "设备接口中未发现绑定地址 $GCLI_PROXY_BIND_IP。"
                return 1
                ;;
            2)
                gcli_proxy_log_diagnostic \
                    "无法读取接口列表；继续交由 Nginx 检查实际绑定。"
                ;;
            *)
                gcli_proxy_log_diagnostic "接口地址检查发生未知错误。"
                return 1
                ;;
        esac
    fi
    gcli_proxy_is_running && return 0
    gcli_proxy_write_nginx_config || return 1
    nginx -p "$GCLI_PROXY_ROOT/" -c "$GCLI_PROXY_CONF" \
        2>> "$GCLI_PROXY_ERROR_LOG" || return 1
    sleep 1
    if ! gcli_proxy_is_running; then
        gcli_proxy_log_diagnostic "Nginx 启动后未通过进程归属检查。"
        return 1
    fi
}

gcli_proxy_start_if_enabled() {
    gcli_proxy_load_settings || {
        warn "LAN API 共享配置无效，未启动 Nginx。"
        return 1
    }
    [[ "$GCLI_PROXY_AUTO_START" == "true" ]] || return 0
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
    if gcli_proxy_is_running; then
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
    local confirm bind_check mode_text
    if ! gcli_proxy_load_settings; then
        err "LAN API 共享配置无效。"
        pause
        return
    fi
    if gcli_proxy_is_running; then
        success "LAN 共享已在 http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT 运行。"
        pause
        return
    fi

    mode_text=$(gcli_proxy_mode_text)
    if [[ "$GCLI_PROXY_MODE" == "full" ]]; then
        echo -e "${YELLOW}完整转发将向 $GCLI_PROXY_ALLOW_CIDR 开放控制面板和凭证管理。${RESET}"
        echo -e "访问仍需随机面板密码，但 HTTP 流量未加密。"
    else
        echo -e "${YELLOW}仅 API 模式将开放 API 路径，并继续阻止控制面板。${RESET}"
    fi
    echo -e "传输仍是 HTTP；请仅在可信局域网使用，并保管好 API 密码。"
    read -rp "确认以 [$mode_text] 启动 $GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if ! gcli_proxy_save_settings; then
        err "无法保存 LAN 共享配置。"
        pause
        return
    fi
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

    if ! gcli_proxy_start_impl; then
        err "LAN API 共享启动失败；后端仍仅监听 127.0.0.1。"
        [[ -f "$GCLI_PROXY_ERROR_LOG" ]] && tail -n 20 "$GCLI_PROXY_ERROR_LOG"
        pause
        return
    fi
    success "LAN 共享已启动：$mode_text。"
    echo -e "API: ${GREEN}http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT/v1${RESET}"
    if [[ "$GCLI_PROXY_MODE" == "full" ]]; then
        echo -e "控制面板: ${GREEN}http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT${RESET}"
        echo -e "请使用菜单 [查看本机访问密码] 中的随机面板密码登录。"
    else
        echo -e "控制面板仍只能从 ${GREEN}http://127.0.0.1:7861${RESET} 访问。"
    fi
    pause
}

gcli_proxy_disable() {
    gcli_proxy_load_settings >/dev/null 2>&1 || gcli_proxy_defaults
    if gcli_proxy_is_running; then
        if ! gcli_proxy_stop_impl; then
            err "无法安全停止属于 ST-Manager 的 Nginx 进程。"
            pause
            return
        fi
        success "当前 LAN 共享已停止；127.0.0.1:7861 不受影响。"
    else
        warn "LAN 共享当前未运行。"
    fi
    if [[ "$GCLI_PROXY_AUTO_START" == "true" ]]; then
        echo -e "${YELLOW}跟随启动仍为开启；下次启动 gcli2api 时会再次启动共享。${RESET}"
    fi
    pause
}

gcli_proxy_toggle_mode() {
    local old_mode target_mode confirm was_running=false
    if ! gcli_proxy_load_settings; then
        err "LAN API 共享配置无效。"
        pause
        return
    fi
    old_mode="$GCLI_PROXY_MODE"
    if [[ "$old_mode" == "api" ]]; then
        target_mode="full"
        echo -e "${YELLOW}完整转发会向 $GCLI_PROXY_ALLOW_CIDR 开放控制面板和凭证管理。${RESET}"
        echo -e "虽然仍有随机面板密码保护，但传输是未加密的 HTTP。"
        read -rp "确认切换到完整转发？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    else
        target_mode="api"
    fi

    if gcli_proxy_is_running; then
        was_running=true
        if ! gcli_proxy_stop_impl; then
            err "无法安全停止 Nginx，模式未修改。"
            pause
            return
        fi
    fi

    GCLI_PROXY_MODE="$target_mode"
    if ! gcli_proxy_save_settings; then
        GCLI_PROXY_MODE="$old_mode"
        if [[ "$was_running" == "true" ]]; then
            gcli_proxy_start_impl >/dev/null 2>&1 || true
        fi
        err "无法保存共享模式；已保留原配置。"
        pause
        return
    fi

    if [[ "$was_running" == "true" ]] && ! gcli_proxy_start_impl; then
        GCLI_PROXY_MODE="$old_mode"
        gcli_proxy_save_settings >/dev/null 2>&1 || true
        gcli_proxy_start_impl >/dev/null 2>&1 || true
        err "新模式启动失败；已尝试恢复原模式。"
        [[ -f "$GCLI_PROXY_ERROR_LOG" ]] && tail -n 20 "$GCLI_PROXY_ERROR_LOG"
        pause
        return
    fi

    success "共享模式已切换为：$(gcli_proxy_mode_text)。"
    pause
}

gcli_proxy_toggle_auto_start() {
    if ! gcli_proxy_load_settings; then
        err "LAN API 共享配置无效。"
        pause
        return
    fi
    if [[ "$GCLI_PROXY_AUTO_START" == "true" ]]; then
        GCLI_PROXY_AUTO_START=false
    else
        GCLI_PROXY_AUTO_START=true
    fi
    if ! gcli_proxy_save_settings; then
        err "无法保存跟随启动设置。"
        pause
        return
    fi
    if [[ "$GCLI_PROXY_AUTO_START" == "true" ]]; then
        success "已开启：启动 gcli2api 时一同启动 LAN 共享。"
        gcli_proxy_is_running || echo -e "${YELLOW}当前未启动；可选择菜单 1 立即启动共享。${RESET}"
    else
        success "已关闭跟随启动；当前运行状态不受影响。"
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
    local choice state mode_text auto_text
    while true; do
        gcli_proxy_load_settings >/dev/null 2>&1 || gcli_proxy_defaults
        if gcli_proxy_is_running; then
            state="${GREEN}运行中${RESET}"
        else
            state="${RED}已停止${RESET}"
        fi
        mode_text=$(gcli_proxy_mode_text)
        if [[ "$GCLI_PROXY_AUTO_START" == "true" ]]; then
            auto_text="${GREEN}开启${RESET}"
        else
            auto_text="${BLUE}关闭${RESET}"
        fi
        clear
        echo -e "${BLUE}=== LAN API 共享（Nginx）===${RESET}"
        echo -e "状态: $state"
        echo -e "模式: $mode_text"
        echo -e "跟随 gcli2api 启动: $auto_text"
        echo -e "地址: $GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT"
        echo -e "允许: $GCLI_PROXY_ALLOW_CIDR"
        echo -e "${BLUE}----------------------------------------------${RESET}"
        echo -e "  ${GREEN}1)${RESET} 立即启动共享"
        echo -e "  ${GREEN}2)${RESET} 停止当前共享"
        echo -e "  ${GREEN}3)${RESET} 切换共享模式"
        echo -e "  ${GREEN}4)${RESET} 切换跟随启动"
        echo -e "  ${GREEN}5)${RESET} 设置 IP、端口和允许网段"
        echo -e "  ${GREEN}6)${RESET} 查看 Nginx 错误日志"
        echo -e "  ${RED}0)${RESET} 返回"
        read_menu_choice "请选择 [0-6]: " 6 || return
        choice="$REPLY"
        case "$choice" in
            1) gcli_proxy_enable ;;
            2) gcli_proxy_disable ;;
            3) gcli_proxy_toggle_mode ;;
            4) gcli_proxy_toggle_auto_start ;;
            5) gcli_proxy_configure ;;
            6) gcli_proxy_logs ;;
            0) return ;;
        esac
    done
}

gcli_show_credentials() {
    if ! gcli_read_stored_passwords; then
        err "无法读取 gcli2api 当前密码。"
        pause
        return
    fi
    echo -e "${YELLOW}请勿截图或分享以下密码。${RESET}"
    echo -e "API 地址: ${GREEN}http://127.0.0.1:7861/v1${RESET}"
    printf 'API 密码: %b%s%b\n' "$GREEN" "$GCLI_API_PASSWORD" "$RESET"
    echo -e "控制面板: ${GREEN}http://127.0.0.1:7861${RESET}"
    printf '面板密码: %b%s%b\n' "$GREEN" "$GCLI_PANEL_PASSWORD" "$RESET"
    if gcli_proxy_load_settings >/dev/null 2>&1 && gcli_proxy_is_running; then
        echo -e "LAN API: ${GREEN}http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT/v1${RESET}"
        if [[ "$GCLI_PROXY_MODE" == "full" ]]; then
            echo -e "LAN 面板: ${GREEN}http://$GCLI_PROXY_BIND_IP:$GCLI_PROXY_BIND_PORT${RESET}"
            echo -e "允许网段: ${GREEN}$GCLI_PROXY_ALLOW_CIDR${RESET}（完整转发）"
        else
            echo -e "允许网段: ${GREEN}$GCLI_PROXY_ALLOW_CIDR${RESET}（控制面板未开放）"
        fi
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
            # asyncpg has no usable Android wheel and compiling it can exhaust
            # the memory of small Termux routers. ST-Manager deliberately uses
            # gcli2api's default local SQLite backend instead of PostgreSQL.
            fastapi|pydantic|asyncpg) continue ;;
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
        POSTGRESQL_URI='' \
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

    if ! gcli_ensure_stored_passwords; then
        err "随机密码初始化失败；服务未启动。"
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
    gcli_ensure_stored_passwords || return 1

    if is_gcli_running; then
        gcli_proxy_start_if_enabled || true
        return 0
    fi

    mkdir -p "$GCLI_CONFIG_DIR" "$GCLI_CREDS_DIR"
    chmod 700 "$GCLI_CONFIG_DIR" "$GCLI_CREDS_DIR"

    if command -v pm2 >/dev/null 2>&1; then
        if gcli_pm2_owned "$GCLI_PM2_NAME"; then
            # Recreate the owned PM2 entry so --update-env cannot retain the
            # old API_PASSWORD/PANEL_PASSWORD/PASSWORD variables.
            pm2 delete "$GCLI_PM2_NAME" >/dev/null 2>&1 || return 1
        fi
        (
            unset API_PASSWORD PANEL_PASSWORD PASSWORD
            env HOST=127.0.0.1 PORT=7861 \
                "POSTGRESQL_URI=" \
                "CREDENTIALS_DIR=$GCLI_CREDS_DIR" \
                pm2 start "$python_bin" --name "$GCLI_PM2_NAME" --cwd "$GCLI_DIR" -- web.py >/dev/null
        ) || return 1
    else
        (
            cd "$GCLI_DIR" || exit 1
            unset API_PASSWORD PANEL_PASSWORD PASSWORD
            exec nohup env HOST=127.0.0.1 PORT=7861 \
                "POSTGRESQL_URI=" \
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

