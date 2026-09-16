# 与你之歌（ST-Manager）安全加固版

ST-Manager 是面向 Android Termux 的 SillyTavern 与 gcli2api 部署、启动、停止、更新和备份工具。

- 原作者：贝露凛倾
- 安全加固维护：Kiro-Durandal Fork
- 版本：v1.2

> 仅供学习与研究。使用者应自行遵守相关服务条款、账号政策和当地法律。

## 安装

从本 Fork 的 `main` 安装：

```bash
cd "$HOME" || exit 1
git clone --depth 1 https://github.com/Kiro-Durandal/ST-beilu-Rapid_deployment.git st-manager-source
bash "$HOME/st-manager-source/ST-Manager/install.sh"
```

安装完成后运行：

```bash
st-menu
```

安装器只支持 Termux。它仅安装缺失的软件包，不会为了“修复环境”把现有 Node.js 强制替换为 `nodejs-lts`，也不会自动安装全局 PM2。系统已经存在 PM2 时会使用它，否则使用带所有权校验的 PID 文件管理进程。

## 本 Fork 的安全改动

### gcli2api

- 强制通过环境变量监听 `127.0.0.1:7861`，不再暴露到同一 Wi-Fi、热点或 VPN 网络。
- 首次安装生成独立的 48 位十六进制 API 密码和面板密码，不再使用默认 `pwd`。
- 密码保存到 `~/.config/st-manager/gcli2api.env`，权限设为 `600`；配置文件按白名单解析，不使用 `source`。
- 固定到已审核提交 `87f56c8cb088f25c58d947d54424cc889ae7c9aa`。
- 安装前核对提交 ID，并对 `web.py` 和 `requirements-termux.txt` 做 SHA-256 校验；失败时拒绝安装。
- 不直接采用上游互相冲突的 Termux 依赖组合；安装时生成本地依赖清单，固定 `FastAPI 0.118.3` 与 `Pydantic 1.10.26`，兼容 Termux 的 Python 3.14 且避免 Pydantic 2 的原生扩展编译问题。
- 依赖安装后运行 `pip check` 并导入完整 `web` 应用；任一步失败都会恢复更新前的安装。
- 不再下载并直接执行上游 `master/termux-install.sh`，因此不会替用户改写 Termux 软件源，也不会执行上游的远程硬重置和自动启动逻辑。
- 更新前完整保留旧目录；凭据目录会复制到新版本。

> Python 包仍由 PyPI/配置的软件源安装。上游 `requirements-termux.txt` 没有为全部传递依赖提供哈希，因此这部分供应链风险只能降低，不能完全消除。

### ST-Manager

- 自更新直接从本 Fork 下载新副本，先执行全部 Shell 语法检查，再备份并替换；不依赖安装目录中的 `.git`。
- 设置文件不再被 `source` 执行。代理地址仅接受 `http`、`https`、`socks5` 或 `socks5h` 的 `主机:端口` 格式。
- 安装和自更新会把旧版本保存在 `~/ST-Manager-backups/`，失败时尝试自动恢复。
- `.bashrc` 自启动使用明确的标记块，只追加一次，不清空、不重写用户原有内容。
- 进程停止前同时核对 PM2 名称、工作目录或 PID、`/proc` 工作目录和命令行，不再使用宽泛的 `pkill -f`。

### SillyTavern

- 保持官方 `release` 分支为默认安装来源。
- 常规更新使用 `git pull --ff-only`。
- 更新、强制更新和切换分支前自动备份 `public`、`data`、`config.yaml`、Git 差异及状态。
- 强制更新仍会运行 `git reset --hard`，但只有用户在对应菜单中再次确认后才执行，并且会先完成备份。

## 目录结构

```text
ST-Manager/
├── core.sh
├── install.sh
├── conf/settings.conf
└── modules/
    ├── sillytavern/
    │   ├── functions.sh
    │   └── menu.conf
    └── gcli2api/
        ├── functions.sh
        └── menu.conf
tests/
└── security_checks.sh
```

在 Bash 环境中可运行 `bash tests/security_checks.sh`，检查全部 Shell 语法和关键安全约束。

## 访问地址

- SillyTavern：`http://127.0.0.1:8000`
- gcli2api API：`http://127.0.0.1:7861/v1`
- gcli2api 控制面板：`http://127.0.0.1:7861`

通过 `st-menu` → `gcli2api 管理` → `查看本机访问密码` 查看随机密码。请勿截图、上传或分享这些密码。

## 更新与恢复

- 更新管理器：`系统管理` → `更新管理工具`
- 更新 SillyTavern：`SillyTavern 管理` → `更新（自动备份）`
- 更新 gcli2api：重新选择 `安装/更新（固定审核版本）`
- 备份目录：`~/ST-Manager-backups/`

自动备份不会自动删除。确认新版本长期稳定后，可手动清理不再需要的旧备份。

## 上游项目

- [原 ST-Manager](https://github.com/beilusaiying/ST-beilu-Rapid_deployment)
- [gcli2api](https://github.com/su-kaka/gcli2api)
- [SillyTavern](https://github.com/SillyTavern/SillyTavern)
- [ERALINK](https://github.com/404nyaFound/eralink)

本 Fork 继续遵循仓库中的许可证与上游组件各自的许可证。
