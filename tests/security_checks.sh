#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find "$ROOT/ST-Manager" -type f -name '*.sh' -print0)

if grep -R -n -F -e 'pkill -f' -e 'nodejs-lts' -e 'master/termux-install.sh' \
    --include='*.sh' "$ROOT/ST-Manager"; then
    echo "发现已禁止的不安全命令。" >&2
    exit 1
fi

grep -Fq 'GCLI_COMMIT="87f56c8cb088f25c58d947d54424cc889ae7c9aa"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_FASTAPI_VERSION="0.118.3"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PYDANTIC_VERSION="1.10.26"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'gcli_write_compat_requirements' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'gcli_python_smoke_test' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'fastapi|pydantic|asyncpg) continue' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'POSTGRESQL_URI=' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'MONGODB_URI=' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'start_all_services()' "$ROOT/ST-Manager/core.sh"
grep -Fq 'stop_all_services()' "$ROOT/ST-Manager/core.sh"
grep -Fq 'autostart_menu:开机自启动' "$ROOT/ST-Manager/core.sh"
grep -Fq 'MODULE_GROUP_ORDER["$sys_group"]="fix_env update_self settings_menu autostart_menu visit_github visit_discord"' \
    "$ROOT/ST-Manager/core.sh"
grep -Fq 'exec bash "$CORE_FILE" --boot-start' "$ROOT/ST-Manager/core.sh"
grep -Fq 'gcli_proxy_start_if_enabled || true' "$ROOT/ST-Manager/core.sh"
grep -Fq '已要求 Nginx 跟随启动，但启动或验证失败。' "$ROOT/ST-Manager/core.sh"
grep -Fq 'read_menu_choice()' "$ROOT/ST-Manager/core.sh"
grep -Fqx 'ST_MANAGER_SECURITY_PROFILE="termux-loopback-secrets-v1"' \
    "$ROOT/ST-Manager/core.sh"
grep -Fq 'RELEASE_VALIDATION_ERROR' "$ROOT/ST-Manager/core.sh"
grep -Fq 'RELEASE_VALIDATION_ERROR' "$ROOT/ST-Manager/install.sh"
grep -Fqx '# GCLI_COMMIT="cdbaf37003a92de31b8a02512d43df3ed6de3411"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
if grep -Fq '87f56c8cb088f25c58d947d54424cc889ae7c9aa' \
    "$ROOT/ST-Manager/core.sh" "$ROOT/ST-Manager/install.sh"; then
    echo "管理器更新校验仍绑定到当前 gcli2api 提交。" >&2
    exit 1
fi
if grep -Eq '^GCLI_COMMIT="cdbaf37003a92de31b8a02512d43df3ed6de3411"$' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"; then
    echo "旧版桥接标记不得成为实际安装提交。" >&2
    exit 1
fi
grep -Fq 'env HOST=127.0.0.1 PORT=7861' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'openssl rand -hex 24' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'gcli_ensure_stored_passwords' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'INSERT OR IGNORE INTO config' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'unset API_PASSWORD PANEL_PASSWORD PASSWORD' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'pm2 delete "$GCLI_PM2_NAME"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
if grep -Fq '"API_PASSWORD=$GCLI_API_PASSWORD"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh" || \
   grep -Fq '"PANEL_PASSWORD=$GCLI_PANEL_PASSWORD"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"; then
    echo "gcli2api 密码仍被作为服务环境变量注入。" >&2
    exit 1
fi
grep -Fq 'validate_proxy_url()' "$ROOT/ST-Manager/core.sh"
grep -Fq 'gcli_lan_proxy_menu=LAN API 共享（Nginx）' \
    "$ROOT/ST-Manager/modules/gcli2api/menu.conf"
grep -Fq 'GCLI_PROXY_BIND_IP="192.168.0.1"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PROXY_BIND_PORT=7861' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PROXY_ALLOW_CIDR="192.168.0.0/24"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PROXY_MODE="api"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PROXY_AUTO_START=false' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'gcli_proxy_toggle_mode()' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'gcli_proxy_toggle_auto_start()' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq '[[ "$GCLI_PROXY_AUTO_START" == "true" ]] || return 0' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'if [[ "$GCLI_PROXY_MODE" == "full" ]]; then' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'listen ${GCLI_PROXY_BIND_IP}:${GCLI_PROXY_BIND_PORT};' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'allow ${GCLI_PROXY_ALLOW_CIDR};' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'deny all;' "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'proxy_buffering off;' "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'location / {' "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq '无法读取接口列表；继续交由 Nginx 检查实际绑定。' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq '2>> "$GCLI_PROXY_ERROR_LOG"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"

(
    proxy_test_root=$(mktemp -d)
    trap 'rm -rf -- "$proxy_test_root"' EXIT
    source "$ROOT/ST-Manager/modules/gcli2api/functions.sh"

    GCLI_CONFIG_DIR="$proxy_test_root/config"
    GCLI_PROXY_SETTINGS_FILE="$GCLI_CONFIG_DIR/gcli2api-lan.conf"
    GCLI_PROXY_ROOT="$GCLI_CONFIG_DIR/nginx"
    GCLI_PROXY_CONF="$GCLI_PROXY_ROOT/nginx.conf"
    GCLI_PROXY_ERROR_LOG="$GCLI_PROXY_ROOT/logs/error.log"
    GCLI_PROXY_PID_FILE="$GCLI_PROXY_ROOT/logs/nginx.pid"
    mkdir -p "$GCLI_CONFIG_DIR"

    # Existing v1.4 settings migrate to API-only with the old startup intent.
    printf '%s\n' \
        'ENABLED=true' \
        'BIND_IP=192.168.0.1' \
        'BIND_PORT=7861' \
        'ALLOW_CIDR=192.168.0.0/24' > "$GCLI_PROXY_SETTINGS_FILE"
    gcli_proxy_load_settings
    [[ "$GCLI_PROXY_MODE" == "api" ]]
    [[ "$GCLI_PROXY_AUTO_START" == "true" ]]
    gcli_proxy_save_settings
    grep -Fxq 'MODE=api' "$GCLI_PROXY_SETTINGS_FILE"
    grep -Fxq 'AUTO_START=true' "$GCLI_PROXY_SETTINGS_FILE"

    # Stub only the syntax check; inspect both generated Nginx policies.
    nginx() { return 0; }
    GCLI_PROXY_MODE="api"
    gcli_proxy_write_nginx_config
    grep -Fq 'return 403;' "$GCLI_PROXY_CONF"
    ! grep -Fq 'Full forwarding exposes' "$GCLI_PROXY_CONF"

    GCLI_PROXY_MODE="full"
    gcli_proxy_write_nginx_config
    grep -Fq 'Full forwarding exposes' "$GCLI_PROXY_CONF"
    ! grep -Fq 'return 403;' "$GCLI_PROXY_CONF"
)

(
    autostart_test_root=$(mktemp -d)
    trap 'rm -rf -- "$autostart_test_root"' EXIT
    source "$ROOT/ST-Manager/core.sh"

    load_modules
    [[ " ${MODULE_GROUP_ORDER[系统管理]} " == *" autostart_menu "* ]]

    ST_MANAGER_STATE_DIR="$autostart_test_root/config"
    AUTOSTART_CONFIG_FILE="$ST_MANAGER_STATE_DIR/autostart.conf"
    AUTOSTART_BOOT_DIR="$autostart_test_root/boot"
    AUTOSTART_BOOT_SCRIPT="$AUTOSTART_BOOT_DIR/20-st-manager"
    AUTOSTART_LOG_FILE="$ST_MANAGER_STATE_DIR/boot.log"

    AUTOSTART_MODE="both"
    autostart_save_config
    autostart_defaults
    autostart_load_config
    [[ "$AUTOSTART_MODE" == "both" ]]

    autostart_write_boot_script
    autostart_script_owned
    grep -Fq 'exec bash "$CORE_FILE" --boot-start' "$AUTOSTART_BOOT_SCRIPT"
    grep -Fq 'sleep 30' "$AUTOSTART_BOOT_SCRIPT"

    GCLI_DIR="$autostart_test_root/gcli2api"
    ST_DIR="$autostart_test_root/SillyTavern"
    GCLI_PROXY_ERROR_LOG="$autostart_test_root/nginx-error.log"
    mkdir -p "$GCLI_DIR" "$ST_DIR"
    : > "$GCLI_DIR/web.py"
    : > "$ST_DIR/server.js"

    sleep() { :; }
    gcli_start_impl() {
        : > "$autostart_test_root/gcli.started"
        return 0
    }
    gcli_proxy_load_settings() {
        GCLI_PROXY_AUTO_START=true
        return 0
    }
    gcli_proxy_is_running() {
        [[ -f "$autostart_test_root/nginx.started" ]]
    }
    gcli_proxy_start_if_enabled() {
        : > "$autostart_test_root/nginx.started"
        return 0
    }
    is_st_running() { return 1; }
    st_start_impl() {
        : > "$autostart_test_root/st.started"
        return 0
    }

    boot_start_services
    [[ -f "$autostart_test_root/gcli.started" ]]
    [[ -f "$autostart_test_root/nginx.started" ]]
    [[ -f "$autostart_test_root/st.started" ]]
)

echo "ST-Manager security checks passed."
