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
grep -Fq 'validate_proxy_url()' "$ROOT/ST-Manager/core.sh"
grep -Fq 'gcli_lan_proxy_menu=LAN API 共享（Nginx）' \
    "$ROOT/ST-Manager/modules/gcli2api/menu.conf"
grep -Fq 'GCLI_PROXY_BIND_IP="192.168.0.1"' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PROXY_BIND_PORT=7861' \
    "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
grep -Fq 'GCLI_PROXY_ALLOW_CIDR="192.168.0.0/24"' \
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

echo "ST-Manager security checks passed."

