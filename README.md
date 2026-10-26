# 与你之歌（ST-Manager）安全加固版

ST-Manager 是面向 Android Termux 的 SillyTavern 与 agy2api 部署、启动、停止、更新和备份工具。

- 原作者：贝露凛倾
- 安全加固维护：Kiro-Durandal Fork
- 版本：v1.9

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

后端默认仍只监听 `127.0.0.1:7861`。需要让 F50 或其他 Termux 设备为局域网提供服务时，可在“agy2api 管理 → LAN API 共享（Nginx）”中启用轻量反向代理。默认绑定 `192.168.0.1:7861`、仅允许 `192.168.0.0/24`；绑定 IP、端口和允许网段均可修改。共享支持“仅 API”和“完整转发”两种模式，并可独立设置是否跟随后端自动启动。旧 gcli2api 的 `/logs/stream` WebSocket 仅在旧后端上生成兼容转发规则；新 agy2api 已由上游移除此实时控制台页面，改用受密码保护的请求统计日志页面。

“系统管理 → 开机自启动”可以生成由 Termux:Boot 执行的最小启动脚本，并选择仅启动 agy2api、仅启动 SillyTavern 或同时启动两者。若启动组合包含 agy2api，Nginx 会继续服从 LAN 共享中的“跟随 agy2api 启动”开关；管理器会在启动后验证 Nginx 状态，首次失败时等待 LAN 接口并重试一次，最终结果写入开机日志。

## 本 Fork 的安全改动

### agy2api

- 强制通过环境变量监听 `127.0.0.1:7861`，不再暴露到同一 Wi-Fi、热点或 VPN 网络。
- 首次安装生成独立的 48 位十六进制 API 密码和面板密码，不再使用默认 `pwd`。
- 首次生成的密码种子保存到 `~/.config/st-manager/agy2api.env`，权限设为 `600`；配置文件按白名单解析，不使用 `source`。实际密码写入 agy2api 的 SQLite 配置后不再作为环境变量注入，因此控制面板可以修改并持久保存 API 密码、面板密码和兼容用通用密码。
- 启动时会重建属于 ST-Manager 的 PM2 记录并清除旧的 `API_PASSWORD`、`PANEL_PASSWORD` 与 `PASSWORD` 环境变量，避免上游把密码输入框锁成只读；随机种子只在 SQLite 尚无对应密码时使用，不会覆盖之后在控制面板保存的值。
- 固定到维护 Fork 的 agy2api 提交 `7aee73d3f015f28d233323adf46ba985ec7a4927`，其中加强了 Chat Completions 的 system、developer 和工具消息转换。新版只保留 Antigravity 通道；GeminiCLI 通道已被上游移除，Gemini 格式的 API 本身仍受支持。
- 安装前核对提交 ID，并对 `web.py` 和 `requirements.txt` 做 SHA-256 校验；失败时拒绝安装。实际下载与高级同步使用 `https://github.com/Kiro-Durandal/agy2api.git`。源码中的 `modules/gcli2api/`、`gcli_*`、`GCLI_*` 和旧 URL 别名保留为升级兼容接口，旧版更新器仍可验证本版本；旧自启动配置中的 `gcli` 值也继续有效。
- 新版依赖固定 `FastAPI 0.162.0`、`Pydantic 2.14.1`、`SQLAlchemy 2.1.6`、`greenlet 3.5.6`；启动旧版安装时仍按其原有 `FastAPI 0.118.3` / `Pydantic 1.10.26` 检查，因此更新管理器本身不会强制升级正在使用的旧后端。
- F50/Termux 使用本地 SQLite，依赖清单排除 PostgreSQL 专用的 `asyncpg`。全部依赖必须通过 `--only-binary=:all:` 下载成功后才停止旧服务，安装也只从已下载 wheel 离线进行；不会回退到 Rust/C/C++ 源码编译。
- 依赖安装后运行 `pip check`、完整应用导入与临时 SQLite 启动测试。测试不打开真实凭据库，也不调用 Google。安装、迁移或重启失败时尝试恢复旧目录及运行状态。
- 默认“安装/更新”使用经过本 Fork 审核并锁定提交与 SHA-256 的版本；“更新与维护 → 检查/同步上游最新版（需确认）”可按需读取上游 `master` 的精确提交号，经用户输入 `UPDATE` 明确确认后再暂存安装。高级同步仍执行 Git 对象检查、依赖兼容处理、完整应用导入测试和失败回滚，但候选代码没有经过本 Fork 人工审核。
- 可选安装独立 Nginx 反向代理。“仅 API”模式只转发 `/v1/`、`/v1beta/`、`/antigravity/v1/`、`/antigravity/v1beta/` 和 `/keepalive`，控制面板、凭据、日志及静态页面对 LAN 返回 `403`；“完整转发”模式会同时开放受随机面板密码保护的控制面板和凭证管理，方便无本机浏览器的 F50 配置凭证。
- 当前运行状态、共享模式和“跟随 agy2api 启动”开关相互独立；新配置默认关闭跟随启动，旧版 `ENABLED` 设置会安全迁移以保持原行为。
- LAN 共享拒绝 `0.0.0.0` 和公网地址，只接受设备实际拥有的 RFC 1918 私有 IPv4、`1024-65535` 端口和包含绑定地址的私有 CIDR；流式响应关闭 Nginx 缓冲。
- 不再下载并直接执行上游 `master/termux-install.sh`，因此不会替用户改写 Termux 软件源，也不会执行上游的远程硬重置和自动启动逻辑。
- 更新前完整保留旧目录；凭据目录会复制到新版本。

> Python 包仍由 PyPI/配置的软件源下载。上游依赖没有为全部传递依赖提供哈希，因此这部分供应链风险只能降低，不能完全消除。禁止现场编译也不等于已经验证 F50 的整机内存占用和稳定性。

#### F50 迁移到 agy2api

安装/更新已自动运行全部停服前检查。若要只检查不安装，进入 `agy2api 管理 → 更新与维护 → 仅检查审核版兼容性（不停服）`。该操作下载并解析依赖，并在临时环境加载、测试 greenlet 与 Pydantic Core；不停止旧服务、不移动安装目录、不修改凭据。缺少匹配 Python/CPU 的 wheel、原生模块加载失败或网络失败时会退出，并显示错误。

截至 2026-10-24，默认 PyPI 缺少这两个版本的 Android wheel，但 [Termux 官方仓库提供预编译 python-greenlet](https://github.com/termux/termux-packages/blob/master/packages/python-greenlet/build.sh)，[TUR 社区提供匹配的 Pydantic Core wheel](https://github.com/tur-pypi-dists/python3.14-pydantic_core/releases/tag/v2.50.1)。Python 3.14 / ARM64 可选择 `agy2api 管理 → 更新与维护 → 修复 F50 预编译依赖（Termux/TUR）` 并明确确认来源：

- 从当前 Termux APT 下载 `python-greenlet 3.5.6`，校验 APT 元数据的 SHA-256，提取官方已编译文件并重新打包为 wheel；不执行包安装脚本、不编译。
- 从固定 TUR 发布地址下载 `pydantic-core 2.50.1`，校验管理器中固定的 SHA-256。TUR 是第三方社区来源，确认前请考虑这项信任。
- 保存到 `~/.config/st-manager/wheels/`，不改 Termux 软件源或 pip 全局索引。也可自行提供信任且匹配的 wheel。

准备完成后，直接安装/更新，或在维护菜单中仅检查审核版兼容性。只有设备上的真实原生模块加载测试通过才继续；桌面打包与依赖解析测试不能证明 F50 运行稳定。缺包或测试失败时请继续使用旧后端，不要删除 `--only-binary` 限制来强行编译。

依赖检查通过后，再执行“安装/更新（审核稳定版）”：

1. 下载锁定提交和全部预编译依赖。
2. 停止旧服务，将完整旧目录移动到 `~/ST-Manager-backups/`。
3. 复制凭据和数据，在副本上把旧 Antigravity 表转换为新 email 键结构，保留旧表档案、密码、禁用状态、冷却与 tier；原备份不修改。
4. 检查迁移和启动，失败时恢复旧版本。缺少有效邮箱/refresh token、重复邮箱或不认识的表结构会中止迁移，避免静默覆盖账号。

新安装默认使用 `~/agy2api`；已有 `~/gcli2api` 或旧配置时继续使用原路径，不搬动包含绝对路径的虚拟环境，不重置密码、LAN 配置和自启动选择。若两个安装目录同时存在，将提示并拒绝安装/启动，避免误选账号库。新日志使用 `agy.log`，旧 `gcli.log` 不删除，尚无新日志时回退读取旧日志。新后端的本机 API 地址为 `http://127.0.0.1:7861/v1`；使用旧本机 `/antigravity/v1` 地址的客户端需改成 `/v1`。Nginx 在识别到新版后，会为 LAN 请求兼容转写旧的 `/antigravity/v1` 和 `/antigravity/v1beta` 路径。

HTTP 正文捕获功能未增加；新上游的 `request_log_enabled` 在首次迁移时保持关闭。旧 GeminiCLI 凭据保留在数据库与完整备份中，但新上游无法使用它们。

用户已反馈 Python 3.14 / ARM64 的免编译方案在 F50 可用；这不保证后续任意上游版本或不同设备都兼容。

### ST-Manager

- 自更新直接从本 Fork 下载新副本，先执行全部 Shell 语法检查，再备份并替换；不依赖安装目录中的 `.git`。
- 自更新按稳定的安全基线检查来源、提交/哈希锁定、仅本机监听、随机密码和 Python 冒烟测试，不再把管理器升级绑定到某一个 agy2api 提交号。
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
    └── gcli2api/  # 保留的旧模块接口，实际服务为 agy2api
        ├── functions.sh
        └── menu.conf
tests/
└── security_checks.sh
```

在 Bash 环境中可运行 `bash tests/security_checks.sh`，检查全部 Shell 语法和关键安全约束。还可运行 `bash tests/install_transaction.sh`、`bash tests/agy_transition.sh` 和 `python -m unittest discover -s tests -p 'test_*.py'`。真实上游运行测试需设置 `AGY_UPSTREAM_ROOT` 并安装审核版 Python 依赖，真实 Termux 包测试需设置 `TERMUX_NATIVE_PAYLOAD`；桌面测试不能执行 Android 原生扩展。

## 访问地址

- SillyTavern：`http://127.0.0.1:8000`
- agy2api API：`http://127.0.0.1:7861/v1`
- agy2api 控制面板：`http://127.0.0.1:7861`

启用 LAN 共享后，API 使用配置的 LAN 地址；只有“完整转发”模式允许从同一地址访问控制面板。完整转发仅适合可信局域网，因为 HTTP 本身不加密。

通过 `st-menu` → `agy2api 管理` → `查看访问地址与密码` 查看 SQLite 中当前生效的 API 与面板密码。控制面板修改后此处会同步显示新值；通用密码只是未单独设置 API/面板密码时的兼容回退项。请勿截图、上传或分享这些密码。

## F50 开机自启动

开机自启动依赖 [Termux:Boot](https://github.com/termux/termux-boot)。Termux 与 Termux:Boot 必须来自同一安装来源并使用相同签名；安装后至少手动打开 Termux:Boot 一次，并允许 Termux 与 Termux:Boot 开机启动、后台运行及忽略电池优化。

进入 `st-menu` → `系统管理` → `开机自启动`：

1. 选择启动组件：仅 agy2api、仅 SillyTavern 或两者同时。
2. 选择“启用/刷新开机启动脚本”。
3. 使用“立即测试启动”验证当前组合。
4. 重启 F50 后使用“查看开机启动日志”检查结果。

启动脚本先等待 30 秒，让 Android 和 F50 的 LAN 接口完成初始化。若 Nginx 已设置为跟随 agy2api 启动但首次未运行，管理器会再等待 10 秒、重试一次并验证进程；重试仍失败时会在日志中明确报错，而不会把它误报为启动成功。

## 更新与恢复

日常 `agy2api 管理` 由九项精简为七项：安装/更新审核稳定版、启动、停止、日志、访问地址与密码、LAN 共享、更新与维护。维护子菜单集中放置上游同步、F50 预编译依赖修复、仅检查兼容性；正常安装不必重复手工检查。

可以按需跟进上游，但不会无人值守追新：读取官方 `master` 的精确 SHA，显示当前版本、提交和变更对比链接，经 `UPDATE` 确认才暂存代码。同步前用 PEP 440 规则核对上游声明是否允许当前已验证的依赖锁；若新版要求更高的 Pydantic/Core、greenlet 或其他冲突版本，就中止而不是强行覆盖。此时需先更新管理器兼容配置并取得可信、匹配设备的 wheel。

缺少构建好的面板时同样在停服前拒绝，不在 F50 运行前端构建。通过依赖/原生加载/临时 SQLite 测试后才停服、备份、安装和迁移，失败时尝试回滚。上游代码未经过本 Fork 人工审核，检查不能保证 Google 登录、模型业务或未来数据库变更完全兼容；大重构仍需单独审核。不要直接在运行目录 `git pull` 绕过管理器流程。

- 更新管理器：`系统管理` → `更新管理工具`
- 更新 SillyTavern：`SillyTavern 管理` → `更新（自动备份）`
- 更新 agy2api（推荐）：选择 `安装/更新（审核稳定版）`
- 检查并试用上游最新提交：选择 `更新与维护 → 检查/同步上游最新版（需确认）`；先核对显示的提交链接，再输入 `UPDATE`
- 备份目录：`~/ST-Manager-backups/`

自动备份不会自动删除。确认新版本长期稳定后，可手动清理不再需要的旧备份。

## 上游项目

- [原 ST-Manager](https://github.com/beilusaiying/ST-beilu-Rapid_deployment)
- [agy2api](https://github.com/su-kaka/agy2api)
- [SillyTavern](https://github.com/SillyTavern/SillyTavern)
- [ERALINK](https://github.com/404nyaFound/eralink)

本 Fork 继续遵循仓库中的许可证与上游组件各自的许可证。
