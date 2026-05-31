# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

AI Monitor 是一个开源、本地优先的 AI 工作监控台。

它会从 Claude Code、Codex CLI、Cursor、浏览器 AI 应用、IDE 扩展、GitHub coding-agent 页面和终端任务中收集任务状态，然后在一个本地 macOS 悬浮面板里显示哪些任务正在运行、已经完成、失败了，或者正在等待输入。

## 当前状态

这个仓库是源码版。目前这个仓库还没有发布打包好的安装器。

当前桌面应用目标是 macOS。Windows 和 Linux 桌面应用还没有实现。

## 环境要求

- macOS 13.0 或更高版本，用于桌面悬浮面板。
- Rust toolchain，用于 daemon 和核心 crates。
- Xcode Command Line Tools，用于 Swift macOS UI 开发。
- Node.js，用于终端和 agent hook 集成。
- Chrome 或其他 Chromium 浏览器，用于当前浏览器扩展工作流。

## 预览

![AI Monitor 悬浮面板预览](docs/images/floating-monitor.png)

![AI Monitor 通知预览](docs/images/notification.png)

## 从源码快速启动

克隆仓库：

```bash
git clone https://github.com/notracc1210/ai-monitor-public.git
cd ai-monitor-public
```

启动本地 daemon：

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

另开一个终端，打开 macOS 悬浮监控窗口：

```bash
./scripts/run_macos_floating_window.sh
```

daemon 会创建本地 API token：

```txt
~/.ai-monitor/api-token
```

浏览器扩展或编辑器集成需要 token 时，使用这个文件里的值。

## 构建本地 App Bundle

本地 macOS 开发可以构建 app bundle：

```bash
./scripts/build_macos_app.sh
open "target/macos-app/AI Monitor.app"
```

这是本地开发构建，适合测试菜单栏应用、设置窗口、随包 daemon 行为和点击返回工作窗口等功能。

## 集成

AI Monitor 通过一组小适配器把任务状态上报到本地 daemon。

| 来源 | 当前支持 |
| --- | --- |
| 浏览器 | Chrome 扩展，支持 ChatGPT、Claude、Gemini、Perplexity、Grok 和 GitHub coding-agent 页面。 |
| IDE | VS Code 和 Cursor 扩展。JetBrains 集成目前以源码形式存在。 |
| 终端 | shell 命令、Claude Code hooks、Codex CLI hooks、精简 terminal events 和 Superset terminal hooks。 |
| 桌面应用观察器 | 可选的 macOS Accessibility 本地桌面应用状态观察器，默认关闭。 |

### 浏览器扩展

从源码加载扩展：

```txt
chrome://extensions -> Developer Mode -> Load unpacked -> integrations/browser-extension/chrome
```

打开扩展 popup，把 daemon URL 设为 `http://127.0.0.1:4318`，粘贴本地 API token，然后点击 `Test`。

### VS Code 或 Cursor

从编辑器命令面板安装源码扩展：

```txt
Developer: Install Extension from Location...
```

选择：

```txt
integrations/ide/vscode
```

然后运行：

```txt
AI Monitor: Send Test Event
```

### 终端和 Agent Hooks

安装项目级 hooks：

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

Codex CLI 在运行非托管 command hooks 前需要通过 `/hooks` 信任审查。

也可以手动包装一个命令：

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "Daemon tests" \
  --title "Run daemon tests" \
  -- cargo test
```

## 通知

默认使用本地桌面通知。第三方通知 provider 是可选功能，只有在你配置后才会使用。

当前已有 provider 代码支持 desktop、Slack、Telegram、Discord、Email、ntfy、Pushover、Bark、飞书、企业微信、钉钉、Server 酱和自定义 webhook。

## 隐私和本地数据

AI Monitor 默认本地优先。daemon 默认绑定 `127.0.0.1`，状态保存在你的 Mac 上，并要求本地 API token。

用户数据保存在源码仓库外：

- 配置：`~/Library/Application Support/AI Monitor/config/default.toml`
- 数据库：`~/Library/Application Support/AI Monitor/ai-monitor.db`
- API token：`~/.ai-monitor/api-token`
- 日志：`~/Library/Logs/AI Monitor`

API token 文件会以 `0600` 权限创建。浏览器、终端、Swift 和编辑器客户端使用同一个本地 token。

更多说明见 [docs/privacy.md](docs/privacy.md) 和 [docs/security.md](docs/security.md)。

## 开发检查

运行聚焦检查：

```bash
./scripts/test_terminal_integration.sh
./scripts/test_official_cli_hooks.sh
./scripts/test_browser_detectors.sh
./scripts/test_ide_integrations.sh
```

运行 Rust 测试：

```bash
cargo test --workspace
```

## 项目文档

- [架构](docs/architecture.md)
- [集成](docs/integrations.md)
- [协议和 API](docs/protocol.md)
- [通知系统](docs/notification-system.md)
- [排障](docs/troubleshooting.md)
- [卸载指南](docs/uninstall.md)
