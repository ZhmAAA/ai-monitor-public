# 隐私说明

[English](privacy.md) | [简体中文](privacy.zh-CN.md)

AI Monitor 本地优先。它把数据存在你的 Mac 上，默认不会把你的提示词、AI 回复或工作区路径发送到任何外部服务。

## 本地存储了什么

- 任务状态、任务标题、简短的步骤消息和时间戳
- 上报任务的工具标识（例如 `claude-code`、`chatgpt-web`）
- 导航信息——点击任务时用来返回对应的浏览器标签页或终端窗口

本地数据库的位置取决于你如何启动 daemon：

- **源码运行**（`--database ./ai-monitor.db`）：仓库目录下的 `ai-monitor.db`
- **打包版 App**（未来版本）：`~/Library/Application Support/AI Monitor/ai-monitor.db`

## 默认不会发送到外部的内容

AI Monitor **默认不会**把以下内容发送到任何外部服务：

- 你的提示词或 AI 回复
- 完整的工作区路径
- 截图

只有当你在 `config/default.toml` 里启用了第三方通知 provider（Slack、Telegram 等）时，这些内容才可能离开你的 Mac。即便如此，外发通知里的工作区路径、提示词和回复默认也会被脱敏处理，除非你主动修改默认配置。

## 如何忽略某个工作区

在 `config/default.toml` 里添加忽略规则，然后重启 daemon：

```toml
# 在存储前丢弃来自该目录的所有事件
[[ignore_rules]]
id = "private-workspace"
mode = "ignore"
workspace_prefix = "/Users/you/private-project"

# 本地存储，但不发送到 Slack、Telegram 等外部 provider
[[ignore_rules]]
id = "local-only-chatgpt"
mode = "local_only"
source = "chatgpt-web"
```

`mode = "ignore"` — 事件在存储前被丢弃，什么都不记录。

`mode = "local_only"` — 事件保存在本地，但不发送给任何外部通知 provider。

规则也可以按应用名称或站点关键词匹配。Daemon 在存储前就应用忽略规则，即使某个集成出问题也不会绕过它。

## API Token

Daemon 在 `~/.ai-monitor/api-token` 创建本地 API token，文件权限为 `0600`（只有你的用户账号能读取）。所有集成——浏览器扩展、IDE 扩展、终端 hooks——都用这个 token 与本地 daemon 通信。

不会有任何数据发送到 AI Monitor 的云服务。
