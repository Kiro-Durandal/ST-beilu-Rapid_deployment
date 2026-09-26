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
grep -Fq 'start_all_services()' "$ROOT/ST-Manager/core.sh"
grep -Fq 'stop_all_services()' "$ROOT/ST-Manager/core.sh"
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

echo "ST-Manager security checks passed."
