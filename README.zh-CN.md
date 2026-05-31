# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

AI Monitor 是一个本地优先的 AI 工作监控台，用来同时跟踪多个 AI worker 的运行状态。

它把 Claude Code、Codex CLI、Cursor、浏览器标签页、IDE 扩展、GitHub agents 和终端会话等工具产生的事件统一成一套任务协议。后台 daemon 会保存原始事件、聚合当前任务状态、通过 WebSocket 推送实时更新，并把高价值状态变化发送到桌面通知和第三方通知渠道。

## 当前范围

- Rust daemon，提供 HTTP 和 WebSocket API。
- Agent Task Protocol，用于各类集成统一上报任务状态。
- SQLite 事件存储，保留原始事件历史和当前任务状态。
- 通知规则引擎。
- 支持桌面、Telegram、Slack、Discord、Email、ntfy、Pushover、Bark、飞书、企业微信、钉钉、Server 酱和自定义 webhook 通知。
- 核心任务状态模拟脚本。
- 终端适配器，支持 shell 命令、Claude Code hooks、Codex CLI hooks 和精简 daemon terminal events。
- macOS 菜单栏与悬浮监控窗口。
- Chrome 浏览器扩展、VS Code/Cursor 扩展，以及 JetBrains 源码级集成。

## 本地安装

AI Monitor 目前主要以 macOS 本地应用包发布，要求 macOS 13.0 或更高版本。公开发布构建应同时支持 Apple Silicon 和 Intel Mac；本地开发构建默认使用当前机器架构。

```bash
./scripts/package_macos_app.sh
./scripts/verify_macos_release.sh
```

普通用户应下载 `target/macos-public-release/AI Monitor.dmg` 对应的公开发布产物，而不是直接使用 `target/macos-dist` 里的内部文件。用户打开 DMG 后，阅读 `README.txt`，把 `AI Monitor.app` 拖到 Applications，然后从 Applications 中打开。

DMG 中还包含 `LICENSE.txt`、`THIRD-PARTY-NOTICES.txt`、`PRIVACY.txt`、`TROUBLESHOOTING.txt`、`UNINSTALL.txt` 和一个安全的 `UNINSTALL.command`。卸载脚本会先预览将要清理的路径，并要求输入 `DELETE` 后才会删除文件。

第一次启动时会自动打开设置窗口。之后可以从菜单栏进入设置，复制首次设置指南、打开浏览器扩展安装链接、复制 API token、打开日志和数据目录、复制排障指南、隐私说明、卸载指南，以及安装登录自启动 daemon。

应用会在本地 daemon 离线时自动启动随包携带的 daemon；如果连接测试仍显示离线，可以在设置里手动点击 `Start daemon`。

用户数据默认保存在仓库外：

- 配置：`~/Library/Application Support/AI Monitor/config/default.toml`
- 数据库：`~/Library/Application Support/AI Monitor/ai-monitor.db`
- API token：`~/.ai-monitor/api-token`
- 登录 daemon：公开构建使用 `~/Library/LaunchAgents/<bundle-id>.daemon.plist`；本地开发构建使用 `~/Library/LaunchAgents/local.ai-monitor.daemon.plist`

本地 API 默认要求 AI Monitor token。daemon 会在没有 token 时创建 `~/.ai-monitor/api-token`，权限为 `0600`。macOS 设置里的 `Copy API token` 也会使用同一个 token 文件。终端和 Swift 客户端会自动读取该文件；浏览器扩展用户可以把 token 粘贴到 popup 中。

默认通知只发送到本机桌面。新安装不会预置任何第三方通知 provider；只有当你主动在设置面板或配置文件中添加 provider 时，才会保存第三方通知密钥。

## 本地开发

启动 daemon：

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

daemon 会把 6 小时没有更新的临时任务标记为 stale。可以用 `AI_MONITOR_STALE_AFTER_SECONDS=0` 关闭这项清理，也可以通过 `--stale-after-seconds` 在测试时调低阈值。

开发阶段 provider secret 可以放在环境变量里；生产配置也可以使用 macOS Keychain 引用，例如：

```toml
[[providers]]
id = "slack"
type = "slack"
enabled = true
webhook_url = "keychain://ai-monitor/slack-webhook-url"
```

测试终端集成：

```bash
./scripts/test_terminal_integration.sh
```

测试 Claude Code / Codex CLI 官方 hook 适配器：

```bash
./scripts/test_official_cli_hooks.sh
```

测试浏览器页面检测器：

```bash
./scripts/test_browser_detectors.sh
```

测试 IDE 集成结构：

```bash
./scripts/test_ide_integrations.sh
```

安装项目级终端 hooks：

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

Codex CLI 在运行非托管 command hooks 前需要通过 `/hooks` 信任审查。

用 AI Monitor 包装一个真实命令：

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "Daemon tests" \
  --title "Run daemon tests" \
  -- cargo test
```

从源码直接打开 macOS 悬浮监控窗口：

```bash
./scripts/run_macos_floating_window.sh
```

构建本地 macOS app bundle：

```bash
./scripts/build_macos_app.sh
open "target/macos-app/AI Monitor.app"
```

## 发布构建

本地开发包可以直接用 ad-hoc 签名生成：

```bash
./scripts/package_macos_app.sh
```

面向普通用户的公开 release 应使用 Developer ID 签名、公证、真实 bundle id 和浏览器扩展安装地址：

```bash
export AI_MONITOR_BUNDLE_ID="com.example.aimonitor"
export AI_MONITOR_APP_VERSION="0.1.0"
export AI_MONITOR_APP_BUILD="1"
export AI_MONITOR_MACOS_ARCHS="arm64 x86_64"
export AI_MONITOR_COPYRIGHT="Copyright 2026 Example, Inc."
export AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL="https://chromewebstore.google.com/detail/..."
export AI_MONITOR_CODESIGN_IDENTITY="Developer ID Application: Example"
export AI_MONITOR_NOTARY_PROFILE="ai-monitor-notary"
export AI_MONITOR_RELEASE=1

./scripts/check_macos_release_prereqs.sh
./scripts/release_macos_app.sh
```

`scripts/release_macos_app.sh` 会强制 release mode，检查发布前置条件，构建、签名、公证并 stapling app bundle，打包 notarized DMG，验证 public DMG，并把可上传文件整理到 `target/macos-public-release`。

如果 `PUBLIC_RELEASE_README.txt` 标注为 development staging preview，或者 `RELEASE_MANIFEST.json` 中的 `release_mode` 是 `false`，这个 DMG 只适合内部测试或 GitHub pre-release，不应作为正式公开安装包发布给普通用户。

完整发布清单见 [docs/release.md](docs/release.md)。

## 使用方式

悬浮面板会优先显示 `session_name`，然后是 `window_title`，最后是任务 `title`。这样 Chrome 标签页、终端 session 和 IDE 任务可以显示成不同的工作表面。

终端任务行会显示终端 session、当前命令或步骤、workspace、pid 和 tmux/session 元数据。点击一行会返回对应工作表面。

macOS 面板还包含菜单栏入口，可用于打开监控窗口、进入设置、启动 daemon 和退出应用。设置面板可以管理 daemon URL/token/config path、测试连接、复制 API token、编辑通知 providers、把 provider secret 写入 macOS Keychain、过滤 monitor source group、配置 ignore rules、开关本地可点击通知、申请可选 Accessibility 权限，以及复制不含密钥的诊断摘要。

公开浏览器用户应通过 `RELEASE_MANIFEST.json` 中记录的 Chrome Web Store 或 managed extension 链接安装扩展。内部测试可以打开 `chrome://extensions`，启用 Developer Mode，点击 `Load unpacked`，选择：

```txt
<repo>/integrations/browser-extension/chrome
```

安装 VS Code/Cursor 适配器时，在 VS Code 或 Cursor 里运行 `Extensions: Install from VSIX...`，选择 `target/macos-dist/AI Monitor IDE Extension.vsix`。如果所在分发渠道不支持 VSIX，可以解压 `AI Monitor IDE Extension.zip`，再运行 `Developer: Install Extension from Location...`。

## 核心接口

- `POST /events`
- `POST /terminal/events`
- `GET /live`
- `GET /tasks`
- `GET /tasks/:id`
- `DELETE /tasks/:id`
- `GET /notifications/providers`
- `GET /notifications/deliveries`
- `POST /notifications/deliveries/:id/retry`
- `POST /notifications/test`

## 安全

AI Monitor 是本地 privileged software。默认只绑定 `127.0.0.1`，并要求本地 API token。

深链接和通知动作必须经过校验后才能执行。macOS 客户端会根据 `TaskAction.type`、URL scheme 和 host allowlist 做限制；未知 action type、未知 URL scheme 和非绝对文件路径都会被忽略。

第三方 webhook provider 默认只接收脱敏后的 task 副本：workspace path 会缩减为文件夹名，prompt/reply metadata 会替换为 `[redacted]`，文件动作不会带本地完整路径。
