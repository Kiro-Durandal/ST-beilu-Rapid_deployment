# 与你之歌（ST-Manager）安全加固版

ST-Manager 是面向 Android Termux 的 SillyTavern 与 gcli2api 部署、启动、停止、更新和备份工具。

- 原作者：贝露凛倾
- 安全加固维护：Kiro-Durandal Fork
- 版本：v1.6

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

首页提供“一键启动全部组件”和“一键停止全部组件”。首页及各级数字菜单采用单键操作，按下数字后立即执行，不需要再按 Enter；代理地址、危险操作确认等文本输入仍需按 Enter。

gcli2api 默认仍只监听 `127.0.0.1:7861`。需要让 F50 或其他 Termux 设备为局域网提供服务时，可在“gcli2api 管理 → LAN API 共享（Nginx）”中启用轻量反向代理。默认绑定 `192.168.0.1:7861`、仅允许 `192.168.0.0/24`；绑定 IP、端口和允许网段均可修改。共享支持“仅 API”和“完整转发”两种模式，并可独立设置是否跟随 gcli2api 自动启动。

“系统管理 → 开机自启动”可以生成由 Termux:Boot 执行的最小启动脚本，并选择仅启动 gcli2api、仅启动 SillyTavern 或同时启动两者。若启动组合包含 gcli2api，Nginx 会继续服从 LAN 共享中的“跟随 gcli2api 启动”开关；管理器会在启动后验证 Nginx 状态，首次失败时等待 LAN 接口并重试一次，最终结果写入开机日志。

## 本 Fork 的安全改动

### gcli2api

- 强制通过环境变量监听 `127.0.0.1:7861`，不再暴露到同一 Wi-Fi、热点或 VPN 网络。
- 首次安装生成独立的 48 位十六进制 API 密码和面板密码，不再使用默认 `pwd`。
- 首次生成的密码种子保存到 `~/.config/st-manager/gcli2api.env`，权限设为 `600`；配置文件按白名单解析，不使用 `source`。实际密码写入 gcli2api 的 SQLite 配置后不再作为环境变量注入，因此控制面板可以修改并持久保存 API 密码、面板密码和兼容用通用密码。
- 启动时会重建属于 ST-Manager 的 PM2 记录并清除旧的 `API_PASSWORD`、`PANEL_PASSWORD` 与 `PASSWORD` 环境变量，避免上游把密码输入框锁成只读；随机种子只在 SQLite 尚无对应密码时使用，不会覆盖之后在控制面板保存的值。
- 固定到已审核提交 `87f56c8cb088f25c58d947d54424cc889ae7c9aa`。
- 安装前核对提交 ID，并对 `web.py` 和 `requirements-termux.txt` 做 SHA-256 校验；失败时拒绝安装。
- 不直接采用上游互相冲突的 Termux 依赖组合；安装时生成本地依赖清单，固定 `FastAPI 0.118.3` 与 `Pydantic 1.10.26`，兼容 Termux 的 Python 3.14 且避免 Pydantic 2 的原生扩展编译问题。
- F50/Termux 使用上游默认的本地 SQLite 存储，并排除只供 PostgreSQL 模式使用、需要在 Android 上现场编译的 `asyncpg`，避免低内存设备在 `Building wheel for asyncpg` 阶段被系统杀死。此安装配置不提供 PostgreSQL 存储模式。
- 依赖安装后运行 `pip check` 并导入完整 `web` 应用；任一步失败都会恢复更新前的安装。
- 可选安装独立 Nginx 反向代理。“仅 API”模式只转发 `/v1/`、`/v1beta/`、`/antigravity/v1/`、`/antigravity/v1beta/` 和 `/keepalive`，控制面板、凭据、日志及静态页面对 LAN 返回 `403`；“完整转发”模式会同时开放受随机面板密码保护的控制面板和凭证管理，方便无本机浏览器的 F50 配置凭证。
- 当前运行状态、共享模式和“跟随 gcli2api 启动”开关相互独立；新配置默认关闭跟随启动，旧版 `ENABLED` 设置会安全迁移以保持原行为。
- LAN 共享拒绝 `0.0.0.0` 和公网地址，只接受设备实际拥有的 RFC 1918 私有 IPv4、`1024-65535` 端口和包含绑定地址的私有 CIDR；流式响应关闭 Nginx 缓冲。
- 不再下载并直接执行上游 `master/termux-install.sh`，因此不会替用户改写 Termux 软件源，也不会执行上游的远程硬重置和自动启动逻辑。
- 更新前完整保留旧目录；凭据目录会复制到新版本。

> Python 包仍由 PyPI/配置的软件源安装。上游 `requirements-termux.txt` 没有为全部传递依赖提供哈希，因此这部分供应链风险只能降低，不能完全消除。

### ST-Manager

- 自更新直接从本 Fork 下载新副本，先执行全部 Shell 语法检查，再备份并替换；不依赖安装目录中的 `.git`。
- 自更新按稳定的安全基线检查来源、提交/哈希锁定、仅本机监听、随机密码和 Python 冒烟测试，不再把管理器升级绑定到某一个 gcli2api 提交号。
- v1.3.1 带有旧版更新器兼容桥，已安装的 v1.1/v1.3 可以直接通过“更新管理工具”完成一次性过渡。
- 设置文件不再被 `source` 执行。代理地址仅接受 `http`、`https`、`socks5` 或 `socks5h` 的 `主机:端口` 格式。
- 安装和自更新会把旧版本保存在 `~/ST-Manager-backups/`，失败时尝试自动恢复。
- `.bashrc` 自启动使用明确的标记块，只追加一次，不清空、不重写用户原有内容。
- 进程停止前同时核对 PM2 名称、工作目录或 PID、`/proc` 工作目录和命令行，不再使用宽泛的 `pkill -f`。
- 可在“系统管理 → 开机自启动”中安全创建或移除 `~/.termux/boot/20-st-manager`。管理器只覆盖和删除带自身所有权标记的脚本，启动组合保存在 `~/.config/st-manager/autostart.conf`，开机日志保存在 `~/.config/st-manager/boot.log`。

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

启用 LAN 共享后，API 使用配置的 LAN 地址；只有“完整转发”模式允许从同一地址访问控制面板。完整转发仅适合可信局域网，因为 HTTP 本身不加密。

通过 `st-menu` → `gcli2api 管理` → `查看本机访问密码` 查看 SQLite 中当前生效的 API 与面板密码。控制面板修改后此处会同步显示新值；通用密码只是未单独设置 API/面板密码时的兼容回退项。请勿截图、上传或分享这些密码。

## F50 开机自启动

开机自启动依赖 [Termux:Boot](https://github.com/termux/termux-boot)。Termux 与 Termux:Boot 必须来自同一安装来源并使用相同签名；安装后至少手动打开 Termux:Boot 一次，并允许 Termux 与 Termux:Boot 开机启动、后台运行及忽略电池优化。

进入 `st-menu` → `系统管理` → `开机自启动`：

1. 选择启动组件：仅 gcli2api、仅 SillyTavern 或两者同时。
2. 选择“启用/刷新开机启动脚本”。
3. 使用“立即测试启动”验证当前组合。
4. 重启 F50 后使用“查看开机启动日志”检查结果。

启动脚本先等待 30 秒，让 Android 和 F50 的 LAN 接口完成初始化。若 Nginx 已设置为跟随 gcli2api 启动但首次未运行，管理器会再等待 10 秒、重试一次并验证进程；重试仍失败时会在日志中明确报错，而不会把它误报为启动成功。

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
