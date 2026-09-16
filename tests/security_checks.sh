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

echo "ST-Manager security checks passed."
