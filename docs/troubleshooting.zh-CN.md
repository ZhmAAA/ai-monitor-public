# 排障指南

[English](troubleshooting.md) | [简体中文](troubleshooting.zh-CN.md)

本指南适用于**源码用户**，即通过 `cargo run` 启动 daemon 的用户。

## Daemon 没有运行

Daemon 是一个在终端窗口里运行的进程。检查以下几点：

- 你运行 `cargo run` 的终端窗口是否还开着？关掉它会停止 daemon。
- 如需重新启动 daemon：

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

- 查看那个终端窗口里有没有报错信息。
- 如果提示"address already in use"，说明 4318 端口已被占用：

```bash
lsof -i :4318
```

终止占用该端口的进程，然后重新启动 daemon。

## Token 或鉴权错误（HTTP 401）

Daemon 在首次运行时会在 `~/.ai-monitor/api-token` 创建 API token。读取它：

```bash
cat ~/.ai-monitor/api-token
```

将该值粘贴到浏览器扩展 popup 或 VS Code 的 `AI Monitor: Api Token` 设置里。

如果文件还不存在，先启动一次 daemon——它会在启动时自动创建该文件。

## 浏览器扩展没有上报标签页

- 确认 daemon 终端窗口仍在运行。
- 打开扩展 popup，检查：
  - Daemon URL 为 `http://127.0.0.1:4318`
  - API token 与 `cat ~/.ai-monitor/api-token` 一致
  - Popup 显示 daemon 在线
- 安装或更新扩展后，重新加载对应的 AI 网页。
- 支持的页面：ChatGPT、Claude、Gemini、Perplexity、Grok 和 GitHub coding-agent 页面。
- Chrome 会显示"该扩展程序不是来自 Chrome 应用商店"的警告——这是正常的，扩展直接从 `integrations/browser-extension/chrome` 目录加载。

## 终端任务没有出现

- 确认 Node.js 已安装：`node --version`
- 为你的项目重新安装 hooks：

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/your/repo
```

- 如果 Node.js 未安装，先安装它，再重新运行上面的命令。
- Codex CLI 用户：在 Codex CLI 里打开 `/hooks`，确认 AI Monitor 的 hooks 已被信任。

## IDE 任务没有出现

- 在 VS Code 命令面板（`Cmd+Shift+P`）里运行 **AI Monitor: Send Test Event**。
- 如果失败：确认 daemon 终端在运行，并检查 VS Code 设置里的 `AI Monitor: Api Token` 是否与 `cat ~/.ai-monitor/api-token` 一致。
- Cursor 用户：确认 `AI Monitor: Source` 已设置为 `cursor`。

## 点击任务没有切换到对应应用

AI Monitor 第一次切换焦点到浏览器或终端窗口时，macOS 会弹出权限提示，选择**允许**。

如果你之前拒绝了：系统设置 → 隐私与安全性 → 自动化 → 允许 AI Monitor 控制对应的应用。

## 桌面应用观察器

桌面应用观察器（通过 Accessibility API 读取本地 AI 桌面应用的窗口标题）由打包版 App 的设置面板控制，目前无法在源码 daemon 中配置。

## 通知没有出现

- 源码版本的本地桌面通知通过 `osascript` 发送。如果通知没有出现，检查系统设置 → 通知，允许终端（或运行 daemon 的应用）发送通知。
- 第三方通知 provider 默认关闭。配置方法见 [第三方通知](third-party-notifications.zh-CN.md)，编辑 `config/default.toml` 后重启 daemon。

## 日志

Daemon 的日志输出在你运行 `cargo run` 的终端窗口里，那是你查看日志的主要入口。

如果你通过 `./scripts/install_macos_launch_agent.sh` 安装了 login daemon，日志在：

```
~/Library/Logs/AI Monitor/daemon.out.log
~/Library/Logs/AI Monitor/daemon.err.log
```

打开该目录：

```bash
open ~/Library/Logs/AI\ Monitor
```

## 全新重装

预览将被删除的内容（不会实际删除）：

```bash
./scripts/uninstall_macos_app.sh --dry-run
```

完整清理步骤见[卸载指南](uninstall.zh-CN.md)。
