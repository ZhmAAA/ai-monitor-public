# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

> ⚠️ **现状：** 本仓库目前只有源码，还没有打包好的安装程序。运行需要 Rust、Xcode Command Line Tools 和 Node.js。如果你不熟悉命令行操作，可以等待后续正式发布的打包版 App（见 [Releases](../../releases)）。

AI Monitor 是一个开源、本地优先的 AI 工作监控台。

**例子：** 当你同时开着 Claude Code、Cursor 和几个 ChatGPT 标签页时，AI Monitor 让你一眼看出哪个任务跑完了、哪个失败了、哪个正在等你点"允许"——全部汇聚在 Mac 上的一个悬浮面板里。

它从 Claude Code、Codex CLI、Cursor、浏览器 AI 应用、IDE 扩展、GitHub coding-agent 页面和终端任务中收集状态，在本地 macOS 悬浮面板里显示哪些任务正在运行、已完成、失败或等待输入。

## 当前状态

仅有源码版本。本仓库目前没有发布打包好的安装程序。

当前桌面端目标平台为 macOS。Windows 和 Linux 桌面应用尚未实现。

## 环境要求

- macOS 13.0 或更高版本
- [Rust toolchain](https://rustup.rs) — 用于运行 daemon（后台服务）
- Xcode Command Line Tools — 用于编译悬浮面板（`xcode-select --install`）
- Node.js — 用于终端和 agent hook 集成

## 预览

![AI Monitor 悬浮面板预览](docs/images/floating-monitor.png)

![AI Monitor 通知预览](docs/images/notification.png)

## 快速开始

### 第一步 — 安装依赖工具

安装 Rust（如果还没有）：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

安装 Xcode Command Line Tools（如果还没有）：

```bash
xcode-select --install
```

### 第二步 — 克隆仓库

```bash
git clone https://github.com/notracc1210/ai-monitor-public.git
cd ai-monitor-public
```

### 第三步 — 启动 daemon（后台服务）

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

daemon 是接收所有 AI 工具任务事件的后台服务。**这个终端窗口要一直开着**，关掉它会停止所有监控。

第一次运行时，Cargo 需要下载并编译依赖，可能需要几分钟。

### 第四步 — 打开悬浮面板

**新开一个终端窗口**（让第三步的 daemon 窗口继续运行），然后执行：

```bash
./scripts/run_macos_floating_window.sh
```

这会编译并启动 macOS 悬浮监控窗口，需要 Xcode Command Line Tools。

### 第五步 — 获取 API token

```bash
cat ~/.ai-monitor/api-token
```

daemon 第一次运行时会自动创建这个文件。下面设置浏览器扩展和 IDE 扩展时需要粘贴这个 token。

## 集成

根据你使用的工具，设置对应的适配器。每个适配器负责把工具状态上报给 daemon。

| 来源 | 支持情况 |
| --- | --- |
| 浏览器 | Chrome 扩展，支持 ChatGPT、Claude、Gemini、Perplexity、Grok 和 GitHub coding-agent 页面 |
| IDE | VS Code 和 Cursor 扩展；JetBrains 插件（仅源码形式） |
| 终端 | Claude Code hooks、Codex CLI hooks、shell 命令包装器 |
| 桌面应用观察器 | 可选的 macOS Accessibility 观察器（默认关闭） |

### 浏览器扩展（Chrome）

1. 在 Chrome 中打开 `chrome://extensions`
2. 开启右上角的**开发者模式**
3. 点击**加载已解压的扩展程序**，选择文件夹：`integrations/browser-extension/chrome`

然后打开扩展 popup：
- **Daemon URL** 填写 `http://127.0.0.1:4318`
- 粘贴 API token（来自 `cat ~/.ai-monitor/api-token`）
- 点击 **Test**，确认显示 daemon 在线

安装后，重新加载已打开的 ChatGPT、Claude、Gemini、Perplexity、Grok 或 GitHub coding-agent 标签页。

### VS Code 或 Cursor

1. 打开命令面板（`Cmd+Shift+P`）
2. 运行 **Developer: Install Extension from Location...**
3. 选择文件夹：`integrations/ide/vscode`
4. 运行 **AI Monitor: Send Test Event**，确认正常工作

Cursor 用户：安装后在 VS Code 设置里把 `AI Monitor: Source` 改为 `cursor`。

### 终端和 Agent Hooks（Claude Code、Codex CLI）

为某个项目安装 hooks：

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/your/repo
```

需要 Node.js。如果 Node.js 未安装，脚本会提示并退出，不会做任何修改。

Codex CLI 用户：安装后，在 Codex CLI 里打开 `/hooks`，信任 AI Monitor 的 hooks。

**手动包装任意命令：**

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "我的会话" \
  --title "任务描述" \
  -- 你的命令
```

## 通知

默认启用本地桌面通知。第三方通知渠道（Slack、Telegram、Discord、ntfy、Pushover 等）为可选功能，配置方法见 [docs/third-party-notifications.md](docs/third-party-notifications.md)。

## 隐私和本地数据

AI Monitor 本地优先。daemon 绑定在 `127.0.0.1`，所有数据留在你的 Mac 上，所有客户端使用同一个本地 API token。

从源码运行时，实际生效的配置文件是启动命令里 `--config` 指定的 `./config/default.toml`。编辑它来配置通知、隐私规则和勿扰时段，然后重启 daemon。

| 内容 | 位置 |
| --- | --- |
| 配置文件（源码运行） | 仓库里的 `./config/default.toml` |
| 数据库 | 仓库里的 `./ai-monitor.db`（来自 `--database` 参数） |
| API token | `~/.ai-monitor/api-token` |
| 日志 | daemon 终端窗口的输出 |

关于存储内容和如何排除特定工作区，见 [docs/privacy.md](docs/privacy.md)。

## 文档

**给使用者：**
- [排障指南](docs/troubleshooting.zh-CN.md) — daemon 离线、token 错误、集成不工作
- [卸载指南](docs/uninstall.zh-CN.md) — 移除 daemon 和本地数据
- [隐私说明](docs/privacy.zh-CN.md) — 存了什么、默认不发送什么、怎么忽略某个工作区
- [第三方通知](docs/third-party-notifications.zh-CN.md) — Slack、Telegram、Discord 等配置
