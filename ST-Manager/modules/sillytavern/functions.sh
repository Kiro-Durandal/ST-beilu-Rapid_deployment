#!/usr/bin/env bash

ST_DIR="$HOME/SillyTavern"
ST_PID_FILE="$HOME/.config/st-manager/sillytavern.pid"
ST_PM2_NAME="st-manager-sillytavern"
ST_LEGACY_PM2_NAME="SillyTavern"

get_st_version() {
    if [[ -f "$ST_DIR/package.json" ]]; then
        jq -r '.version // "未知"' "$ST_DIR/package.json" 2>/dev/null
    else
        echo "未安装"
    fi
}

st_pm2_owned() {
    local name="$1"
    command -v pm2 >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    pm2 jlist 2>/dev/null | jq -e \
        --arg name "$name" \
        --arg dir "$ST_DIR" \
        '.[] | select(.name == $name) | select(.pm2_env.pm_cwd == $dir or .pm2_env.pm_exec_path == ($dir + "/server.js"))' \
        >/dev/null 2>&1
}

st_pm2_running() {
    local name="$1" pid
    st_pm2_owned "$name" || return 1
    pid=$(pm2 pid "$name" 2>/dev/null | tail -n 1)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]]
}

st_running_pm2_name() {
    if st_pm2_running "$ST_PM2_NAME"; then
        echo "$ST_PM2_NAME"
        return 0
    fi
    if st_pm2_running "$ST_LEGACY_PM2_NAME"; then
        echo "$ST_LEGACY_PM2_NAME"
        return 0
    fi
    return 1
}

st_pid_matches() {
    local pid="$1" cwd cmdline
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1
    [[ "$cwd" == "$ST_DIR" ]] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    [[ "$cmdline" == *"server.js"* ]]
}

st_fallback_pid() {
    local pid
    [[ -f "$ST_PID_FILE" ]] || return 1
    read -r pid < "$ST_PID_FILE"
    if st_pid_matches "$pid"; then
        echo "$pid"
        return 0
    fi
    rm -f -- "$ST_PID_FILE"
    return 1
}

is_st_running() {
    st_running_pm2_name >/dev/null 2>&1 || st_fallback_pid >/dev/null 2>&1
}

st_status_text() {
    local ver status
    ver=$(get_st_version)
    if is_st_running; then
        status="${GREEN}运行中${RESET}"
    else
        status="${RED}已停止${RESET}"
    fi
    echo -e "SillyTavern: ${GREEN}$ver${RESET} | $status"
}

st_install() {
    if [[ -f "$ST_DIR/package.json" ]]; then
        warn "SillyTavern 已安装；请使用更新功能。"
        pause
        return
    fi
    if [[ -e "$ST_DIR" ]]; then
        err "目标路径已存在且不是有效安装：$ST_DIR"
        pause
        return
    fi

    echo -e "${BLUE}开始安装 SillyTavern release 分支...${RESET}"
    if git clone --depth 1 --branch release https://github.com/SillyTavern/SillyTavern.git "$ST_DIR" &&
       npm --prefix "$ST_DIR" install; then
        success "安装完成"
    else
        err "安装失败；请检查上方日志。"
    fi
    pause
}

st_start_impl() {
    local pid
    [[ -f "$ST_DIR/server.js" ]] || return 1
    if is_st_running; then
        return 0
    fi

    if [[ ! -d "$ST_DIR/node_modules" ]]; then
        npm --prefix "$ST_DIR" install || return 1
    fi

    mkdir -p "$(dirname "$ST_PID_FILE")"
    chmod 700 "$(dirname "$ST_PID_FILE")"

    if command -v pm2 >/dev/null 2>&1; then
        if st_pm2_owned "$ST_PM2_NAME"; then
            pm2 restart "$ST_PM2_NAME" >/dev/null || return 1
        else
            if st_pm2_owned "$ST_LEGACY_PM2_NAME"; then
                pm2 delete "$ST_LEGACY_PM2_NAME" >/dev/null 2>&1 || return 1
            fi
            pm2 start "$ST_DIR/server.js" --name "$ST_PM2_NAME" --cwd "$ST_DIR" \
                --node-args="--max-old-space-size=4096" >/dev/null || return 1
        fi
    else
        (
            cd "$ST_DIR" || exit 1
            exec nohup node --max-old-space-size=4096 server.js
        ) >> "$ST_DIR/st_output.log" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$ST_PID_FILE"
        chmod 600 "$ST_PID_FILE"
    fi

    sleep 3
    is_st_running
}

st_start() {
    if [[ ! -d "$ST_DIR" ]]; then
        warn "未检测到 SillyTavern，准备安装。"
        st_install
    fi

    if is_st_running; then
        warn "SillyTavern 已经在运行。"
    elif st_start_impl; then
        success "SillyTavern 启动成功"
        if command -v termux-open-url >/dev/null 2>&1; then
            termux-open-url "http://127.0.0.1:8000"
        fi
    else
        err "启动失败，请查看日志。"
    fi
    pause
}

st_stop_impl() {
    local name pid stopped=false count
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        pm2 stop "$name" >/dev/null 2>&1 && stopped=true
    done < <(
        st_pm2_running "$ST_PM2_NAME" && echo "$ST_PM2_NAME"
        st_pm2_running "$ST_LEGACY_PM2_NAME" && echo "$ST_LEGACY_PM2_NAME"
    )

    if pid=$(st_fallback_pid 2>/dev/null); then
        kill "$pid" 2>/dev/null || true
        count=0
        while kill -0 "$pid" 2>/dev/null && (( count < 20 )); do
            sleep 0.1
            ((count++))
        done
        if kill -0 "$pid" 2>/dev/null && st_pid_matches "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f -- "$ST_PID_FILE"
        stopped=true
    fi
    [[ "$stopped" == "true" ]]
}

st_stop() {
    if st_stop_impl; then
        success "已停止 ST-Manager 管理的 SillyTavern 进程。"
    else
        warn "未发现属于此安装目录的 SillyTavern 进程。"
    fi
    pause
}

st_logs() {
    local name log_file="$ST_DIR/st_output.log"
    if name=$(st_running_pm2_name 2>/dev/null); then
        pm2 logs "$name" --lines 50 --nostream
    elif [[ -f "$log_file" ]]; then
        tail -n 50 "$log_file"
    else
        warn "暂无日志。"
    fi
    pause
}

st_create_backup() {
    local label="${1:-manual}" stamp backup_file patch_file status_file item
    local items=()
    [[ -d "$ST_DIR" ]] || return 1
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    stamp="$(date +%Y%m%d_%H%M%S)-$$"
    backup_file="$BACKUP_ROOT/sillytavern-${label}-${stamp}.zip"
    patch_file="$BACKUP_ROOT/sillytavern-${label}-${stamp}.patch"
    status_file="$BACKUP_ROOT/sillytavern-${label}-${stamp}.status.txt"

    for item in public data config.yaml; do
        [[ -e "$ST_DIR/$item" ]] && items+=("$item")
    done
    if (( ${#items[@]} > 0 )); then
        (cd "$ST_DIR" && zip -qr "$backup_file" "${items[@]}") || return 1
    fi
    if [[ -d "$ST_DIR/.git" ]]; then
        git -C "$ST_DIR" diff --binary > "$patch_file" || return 1
        git -C "$ST_DIR" status --short > "$status_file" || return 1
    fi
    echo "$backup_file"
}

st_backup_menu() {
    local backup_file
    if ! command -v zip >/dev/null 2>&1; then
        err "缺少 zip，请先运行 '修复运行环境'。"
    elif backup_file=$(st_create_backup manual); then
        success "备份完成: $backup_file"
    else
        err "备份失败。"
    fi
    pause
}

st_update_menu() {
    local opt confirm branch backup_file
    while true; do
        clear
        echo -e "${BLUE}=== SillyTavern 更新管理 ===${RESET}"
        echo -e "  ${GREEN}1)${RESET} 常规更新（仅快进）"
        echo -e "  ${GREEN}2)${RESET} 强制修复更新（丢弃核心文件改动）"
        echo -e "  ${GREEN}0)${RESET} 返回"
        read -rp "选择: " opt
        case "$opt" in
            1)
                if ! backup_file=$(st_create_backup pre-update); then
                    err "自动备份失败；已取消更新。"
                    pause
                    continue
                fi
                log "备份已保存: $backup_file"
                if git -C "$ST_DIR" pull --ff-only && npm --prefix "$ST_DIR" install; then
                    success "更新完成"
                else
                    err "更新失败；备份仍保留。"
                fi
                pause
                ;;
            2)
                echo -e "${RED}警告：将丢弃 SillyTavern 核心文件的本地修改。${RESET}"
                read -rp "确认执行？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if ! backup_file=$(st_create_backup pre-force-update); then
                        err "自动备份失败；已取消更新。"
                        pause
                        continue
                    fi
                    log "备份已保存: $backup_file"
                    branch=$(git -C "$ST_DIR" rev-parse --abbrev-ref HEAD) || {
                        err "无法识别当前分支。"
                        pause
                        continue
                    }
                    if git -C "$ST_DIR" fetch origin "$branch" &&
                       git -C "$ST_DIR" reset --hard "origin/$branch" &&
                       npm --prefix "$ST_DIR" install; then
                        success "强制更新完成"
                    else
                        err "强制更新失败；备份仍保留。"
                    fi
                fi
                pause
                ;;
            0) break ;;
        esac
    done
}

st_switch_branch() {
    local opt target backup_file
    echo -e "${BLUE}当前分支: $(git -C "$ST_DIR" rev-parse --abbrev-ref HEAD)${RESET}"
    echo -e "  ${GREEN}1)${RESET} 切换到 Release（稳定版）"
    echo -e "  ${GREEN}2)${RESET} 切换到 Staging（测试版）"
    read -rp "选择: " opt
    case "$opt" in
        1) target=release ;;
        2) target=staging ;;
        *) pause; return ;;
    esac

    if ! backup_file=$(st_create_backup pre-branch-switch); then
        err "自动备份失败；已取消切换。"
    elif git -C "$ST_DIR" fetch origin "$target" &&
         git -C "$ST_DIR" checkout "$target" &&
         git -C "$ST_DIR" pull --ff-only origin "$target" &&
         npm --prefix "$ST_DIR" install; then
        success "已切换到 $target；备份位于 $backup_file"
    else
        err "分支切换失败；备份仍保留。"
    fi
    pause
}
