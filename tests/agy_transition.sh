#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

run_path_case() (
    transition_root=$(mktemp -d)
    trap 'rm -rf -- "$transition_root"' EXIT
    export HOME="$transition_root/home"
    mkdir -p "$HOME/.config/st-manager"
    case "$1" in
        legacy|conflict)
            mkdir -p "$HOME/gcli2api/creds"
            printf 'unchanged\n' > "$HOME/gcli2api/creds/fixture"
            printf 'fixture-seed\n' > "$HOME/.config/st-manager/gcli2api.env"
            ;;
        state-only)
            printf 'fixture-seed\n' > "$HOME/.config/st-manager/gcli2api.env"
            ;;
        state-priority)
            mkdir -p "$HOME/agy2api"
            printf 'stale-seed\n' > "$HOME/.config/st-manager/gcli2api.env"
            printf 'current-seed\n' > "$HOME/.config/st-manager/agy2api.env"
            ;;
    esac
    [[ "$1" != "conflict" ]] || mkdir -p "$HOME/agy2api"
    source "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
    [[ "$AGY_REPO" == "https://github.com/su-kaka/agy2api.git" ]]
    if [[ "$1" == "legacy" ]]; then
        [[ "$GCLI_DIR" == "$HOME/gcli2api" && "$GCLI_STORAGE_NAME" == "gcli2api" ]]
        [[ "$GCLI_PID_FILE" == "$HOME/.config/st-manager/gcli2api.pid" ]]
        [[ "$GCLI_PROXY_ROOT" == "$HOME/.config/st-manager/gcli2api-nginx" ]]
        grep -Fxq unchanged "$GCLI_CREDS_DIR/fixture"
        grep -Fxq fixture-seed "$GCLI_ENV_FILE"
    elif [[ "$1" == "fresh" ]]; then
        [[ "$GCLI_DIR" == "$HOME/agy2api" && "$GCLI_STORAGE_NAME" == "agy2api" ]]
        [[ "$GCLI_PM2_NAME" == "st-manager-agy2api" ]]
        [[ ! -e "$GCLI_DIR" && ! -e "$GCLI_ENV_FILE" ]]
    elif [[ "$1" == "state-only" ]]; then
        [[ "$GCLI_DIR" == "$HOME/agy2api" && "$GCLI_STORAGE_NAME" == "gcli2api" ]]
        grep -Fxq fixture-seed "$GCLI_ENV_FILE"
    elif [[ "$1" == "state-priority" ]]; then
        [[ "$GCLI_STORAGE_NAME" == "agy2api" ]]
        grep -Fxq current-seed "$GCLI_ENV_FILE"
    else
        [[ "$GCLI_PATH_CONFLICT" == "true" ]]
        err() { :; }; pause() { :; }
        git() { : > "$transition_root/git-called"; return 1; }
        gcli_install_commit "$GCLI_COMMIT"
        [[ ! -f "$transition_root/git-called" ]]
        ! gcli_start_impl
        grep -Fxq unchanged "$HOME/gcli2api/creds/fixture"
    fi
)

run_path_case fresh
run_path_case legacy
run_path_case state-only
run_path_case state-priority
run_path_case conflict

(
    source "$ROOT/ST-Manager/core.sh"
    load_modules
    [[ " ${MAIN_GROUP_ORDER[*]} " == *" agy2api 管理 "* ]]
    [[ "${GROUP_TO_MODULE_MAP[agy2api 管理]}" == "gcli2api" ]]
    read -ra daily_entries <<< "${MODULE_GROUP_ORDER[agy2api 管理]}"
    [[ ${#daily_entries[@]} -eq 7 ]]
    [[ " ${daily_entries[*]} " != *" gcli_check_compatibility "* ]]
    [[ " ${daily_entries[*]} " != *" gcli_prepare_native_wheels "* ]]
    [[ " ${daily_entries[*]} " == *" gcli_maintenance_menu "* ]]
    validate_hardened_release "$ROOT/ST-Manager"
    # Old installed updaters require this alias in addition to the new source.
    grep -Fqx 'GCLI_REPO="https://github.com/su-kaka/gcli2api.git"' \
        "$ROOT/ST-Manager/modules/gcli2api/functions.sh"
    AUTOSTART_MODE=gcli
    [[ "$(autostart_mode_text)" == "仅 agy2api" ]]
    AUTOSTART_MODE=both
    [[ "$(autostart_mode_text)" == "SillyTavern + agy2api" ]]
    for key in "${daily_entries[@]}"; do
        declare -f "${FUNCTION_MAP[$key]}" >/dev/null
    done
)

echo "agy2api transition checks passed."
