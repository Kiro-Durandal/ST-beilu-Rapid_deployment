#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

run_case() (
    test_root=$(mktemp -d)
    trap 'rm -rf -- "$test_root"' EXIT
    # The installer confines all mutations to this disposable fixture HOME.
    export HOME="$test_root/home"
    export PREFIX="/data/data/com.termux/files/usr"
    mkdir -p "$HOME/gcli2api/creds"
    printf 'old\n' > "$HOME/gcli2api/old-version"
    source "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
    BACKUP_ROOT="$HOME/backups"
    BLUE='' GREEN='' YELLOW='' RED='' RESET=''
    mode="$1"
    running=true
    export ST_MANAGER_TRANSACTION_MARKER="$test_root"
    export ST_MANAGER_TRANSACTION_MODE="$mode"
    GCLI_ACTIVE_FASTAPI_VERSION="$GCLI_FASTAPI_VERSION"
    GCLI_ACTIVE_PYDANTIC_VERSION="$GCLI_PYDANTIC_VERSION"
    openssl() { :; }; sha256sum() { :; }
    log() { :; }; success() { :; }; warn() { :; }; err() { :; }; pause() { :; }
    # Match the source-dir position in `git -C DIR checkout ...`.
    git() {
        if [[ "$1" == "init" ]]; then
            mkdir -p "$3"
        elif [[ "${3:-}" == "checkout" ]]; then
            : > "$2/web.py"
            : > "$2/requirements.txt"
        elif [[ "${3:-}" == "rev-parse" ]]; then
            printf '%s\n' "$GCLI_COMMIT"
        fi
        return 0
    }
    python() {
        if [[ "${2:-}" == "profile" ]]; then
            printf 'agy2api\n'
        elif [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
            mkdir -p "$3/bin"
            printf '#!/bin/sh\nif [[ "$2" == "migrate" ]]; then : > "$ST_MANAGER_TRANSACTION_MARKER/migration"; [[ "$ST_MANAGER_TRANSACTION_MODE" != "migration-failure" ]]; exit $?; fi\n: > "$ST_MANAGER_TRANSACTION_MARKER/pip"\nexit 0\n' > "$3/bin/python"
            chmod +x "$3/bin/python"
        fi
        return 0
    }
    gcli_download_wheels() {
        [[ ! -f "$test_root/stopped" ]]
        : > "$test_root/preflight"
        [[ "$mode" != "missing-wheel" ]]
    }
    is_gcli_running() { [[ "$running" == "true" ]]; }
    gcli_proxy_is_running() { return 1; }
    gcli_stop_impl() { : > "$test_root/stopped"; running=false; return 0; }
    gcli_restore_running_state() { : > "$test_root/restored"; running=true; return 0; }
    gcli_python_smoke_test() { [[ "$mode" != "startup-failure" ]]; }
    gcli_ensure_stored_passwords() { : > "$test_root/passwords"; return 0; }
    gcli_show_credentials() { :; }
    gcli_install_commit "$GCLI_COMMIT" "" "" upstream "${2:-}"
    [[ -f "$test_root/preflight" ]]
    if [[ "$mode" == "success" ]]; then
        [[ ! -f "$GCLI_DIR/old-version" && -f "$GCLI_DIR/web.py" ]]
        [[ -f "$test_root/passwords" && -f "$test_root/migration" ]]
        [[ $(find "$BACKUP_ROOT" -name old-version | wc -l) -eq 1 ]]
    else
        [[ -f "$GCLI_DIR/old-version" ]]
    fi
    [[ "$running" == "true" ]]
    case "$mode" in
        missing-wheel|check)
            [[ ! -f "$test_root/stopped" && ! -f "$test_root/restored" ]]
            ;;
        startup-failure)
            [[ -f "$test_root/pip" && ! -f "$test_root/migration" ]]
            [[ -f "$test_root/stopped" && -f "$test_root/restored" ]]
            ;;
        migration-failure)
            [[ -f "$test_root/migration" ]]
            [[ -f "$test_root/stopped" && -f "$test_root/restored" ]]
            ;;
        success) [[ -f "$test_root/stopped" && -f "$test_root/restored" ]] ;;
    esac
)

run_case missing-wheel
run_case check check
run_case startup-failure
run_case migration-failure
run_case success

run_native_case() (
    native_test_root=$(mktemp -d)
    trap 'rm -rf -- "$native_test_root"' EXIT
    source "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
    export ST_NATIVE_TEST_MODE="$1"
    export ST_NATIVE_TEST_MARKER="$native_test_root/events"
    GCLI_CONFIG_DIR="$native_test_root/config"
    mkdir -p "$native_test_root/source/src/storage"
    : > "$native_test_root/source/src/storage/database.py"
    log() { :; }; err() { :; }; warn() { :; }
    gcli_write_compat_requirements() { :; }
    python() {
        if [[ "$2" == "venv" ]]; then
            mkdir -p "$3/bin"
            printf '%s\n' '#!/bin/sh' \
                'if [[ "$1" == "-m" ]]; then' \
                '  printf "install\n" >> "$ST_NATIVE_TEST_MARKER"' \
                '  [[ "$ST_NATIVE_TEST_MODE" != "pip-failure" ]]' \
                'else' \
                '  printf "import\n" >> "$ST_NATIVE_TEST_MARKER"' \
                '  [[ "$ST_NATIVE_TEST_MODE" != "import-failure" ]]' \
                'fi' > "$3/bin/python"
            chmod +x "$3/bin/python"
        fi
        return 0
    }
    if gcli_download_wheels "$native_test_root/source" "$native_test_root/wheels"; then
        [[ "$ST_NATIVE_TEST_MODE" == "success" ]]
    else
        [[ "$ST_NATIVE_TEST_MODE" != "success" ]]
    fi
    grep -Fxq install "$ST_NATIVE_TEST_MARKER"
    if [[ "$ST_NATIVE_TEST_MODE" == "pip-failure" ]]; then
        ! grep -Fxq import "$ST_NATIVE_TEST_MARKER"
    else
        grep -Fxq import "$ST_NATIVE_TEST_MARKER"
    fi
)

run_native_case success
run_native_case pip-failure
run_native_case import-failure
echo "Installer transaction tests passed."
