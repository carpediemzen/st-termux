# st-termux

面向 Android **Termux** 的 [SillyTavern（酒馆）](https://github.com/SillyTavern/SillyTavern) 快速安装、国内源测速与日常维护脚本。

## 特性

- **双模式运行**：无参数进入中文交互菜单，也支持命令行参数非交互一键安装/更新/自检。
- **多链路自动测速与故障顺延**：
  - **Termux APT 源**：读取 Termux 官方收录的中国大陆镜像目录实测延迟，自动切换最快源并清理非交互 `dpkg` 配置阻塞。
  - **GitHub 通道**：自动探测节点是否真实返回 `git-upload-pack` 协议头（过滤返回错误 HTML 页的失效反代），按耗时排序并在克隆/拉取失败时自动顺延下一通道；仓库内始终保持干净的官方 `origin`，不被临时代理锁死。
  - **npm 源**：实测 `npmmirror`、腾讯云、华为云与官方源延迟，安装阶段即提前完成与官方 `start.sh` 一致的生产依赖安装。
- **环境补全与常见坑规避**：
  - 严格拦截 `root` (`uid=0`) 与非 Termux 环境，避免误用 `pkg`。
  - 适配 Termux 新版 `nodejs-lts`（v24+）拆包变化：确保 `node >= 20` 并自动检测补装 `npm`；旧版 `nodejs (< 20)` 自动安全迁移至 `nodejs-lts`。
  - 32 位 ARM (`arm` / `armv7l`) 自动补装 Termux 原生 `esbuild`。
  - 使用 `--depth 1` 单分支浅克隆节省手机空间；重复安装或更新时自动保留 `data/`、`backups/` 与 `config.yaml`。
- **开箱体验优化**：
  - 可选应用安卓 `config.yaml` 性能预设（启用角色卡懒加载、关闭磁盘缓存、禁用桌面自动弹浏览器），自动备份原配置。
  - 幂等写入 shell 快捷命令：`st`（启动）、`stup`（自动测速更新）、`stmenu`（打开管理菜单）。

## 前置准备

请勿使用 Google Play 商店中已停止维护的旧版 Termux，建议从 [F-Droid](https://f-droid.org/packages/com.termux/) 或 [Termux GitHub Releases](https://github.com/termux/termux-app/releases) 安装最新版。

## 快速开始

### 方式一：本地运行（推荐）

```bash
git clone https://github.com/carpediemzen/st-termux.git
cd st-termux
bash install.sh
```

### 方式二：一行命令直接运行

```bash
# 直连 GitHub
curl -fsSL https://raw.githubusercontent.com/carpediemzen/st-termux/main/install.sh | bash

# 若手机端直连 GitHub 较慢，可先加上常用加速前缀（例如）：
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/carpediemzen/st-termux/main/install.sh | bash
```

> 一键全自动静默安装（不询问确认直接应用推荐配置）：
> ```bash
> bash install.sh install -y
> ```

## 命令行用法

```text
用法:
  bash install.sh [命令] [选项]

命令:
  install, --install    一键安装/修复 SillyTavern 并补全运行环境
  update,  --update     安全更新 SillyTavern 与依赖（保留 data/ 与 config.yaml）
  start,   --start      启动 SillyTavern
  doctor,  --doctor     运行 Termux 与酒馆环境自检
  mirror,  --mirror     测速并配置 Termux / GitHub / npm 加速源
  config,  --config     配置性能预设、快捷命令与局域网监听

常用选项:
  -d, --dir <路径>              安装目录 (默认: $HOME/SillyTavern)
  -b, --branch <release|staging> 分支选择 (默认: release)
  --network <auto|cn|official>  网络策略 (默认: auto 优先测速国内源)
  --github-proxy <前缀URL>      自定义 GitHub 加速前缀
  --npm-registry <URL>          自定义 npm 源 URL
  --perf / --no-perf            强制开启或跳过安卓 config.yaml 预设
  --alias / --no-alias          强制开启或跳过写入 shell 快捷指令
  --start-after                 安装完成后立即启动酒馆
  -y, --yes                     非交互自动确认
```

## 常用维护建议

- **防止切后台断连**：在 Termux 下拉通知栏点击 **Acquire wakelock**，或在终端执行 `termux-wake-lock`。
- **局域网手机/电脑访问**：通过 `stmenu` -> `6) 配置` 开启 `listen: true` 后，请务必配置 `config.yaml` 中的 `whitelist` 或开启 `basicAuthMode` 并修改默认账号密码。

## 本地验证

```bash
bash -n install.sh
shellcheck -s bash install.sh
bash tests/test_install.sh
```
