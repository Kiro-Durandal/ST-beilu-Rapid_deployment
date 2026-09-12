#!/usr/bin/env bash

GCLI_DIR="$HOME/gcli2api"
GCLI_REPO="https://github.com/su-kaka/gcli2api.git"
GCLI_COMMIT="cdbaf37003a92de31b8a02512d43df3ed6de3411"
GCLI_WEB_SHA256="27201103ddd0a564d7be2838f9f3ab0c8253f6b048e46c39371991cabbe9246e"
GCLI_REQUIREMENTS_SHA256="c54644f73c84e85263bb0d00630b3c06cef57535631a360756bd485ecffe30d6"
GCLI_CONFIG_DIR="$HOME/.config/st-manager"
GCLI_ENV_FILE="$GCLI_CONFIG_DIR/gcli2api.env"
GCLI_CREDS_DIR="$GCLI_DIR/creds"
GCLI_PID_FILE="$GCLI_CONFIG_DIR/gcli2api.pid"
GCLI_PM2_NAME="st-manager-gcli2api"
GCLI_LEGACY_PM2_NAME="web"

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
    local ver status
    ver=$(get_gcli_version)
    if is_gcli_running; then
        status="${GREEN}运行中（仅本机监听）${RESET}"
    else
        status="${RED}已停止${RESET}"
    fi
    echo -e "gcli2api   : ${GREEN}$ver${RESET} | $status"
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
    pause
}

gcli_verify_file() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]]
}

gcli_stop_impl() {
    local name pid stopped=false
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
    [[ "$stopped" == "true" ]]
}

gcli_install() {
    local packages=() stage_dir source_dir backup_dir="" actual_commit was_running=false
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
    if ! python -m venv "$GCLI_DIR/.venv" ||
       ! "$GCLI_DIR/.venv/bin/python" -m pip install -r "$GCLI_DIR/requirements-termux.txt"; then
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
    echo -e "${GREEN}监听地址已强制设为 127.0.0.1，默认 pwd 已禁用。${RESET}"
    if [[ "$was_running" == "true" ]]; then
        gcli_start_impl || warn "更新完成，但自动重启失败。"
    fi
    gcli_show_credentials
}

gcli_start_impl() {
    local python_bin="$GCLI_DIR/.venv/bin/python" pid
    [[ -x "$python_bin" && -f "$GCLI_DIR/web.py" ]] || return 1
    gcli_ensure_secrets || return 1

    if is_gcli_running; then
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
    is_gcli_running
}

gcli_start() {
    if [[ ! -f "$GCLI_DIR/web.py" ]]; then
        warn "未检测到 gcli2api，请先安装。"
    elif is_gcli_running; then
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
