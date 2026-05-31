# 卸载指南

[English](uninstall.md) | [简体中文](uninstall.zh-CN.md)

## 停止 Daemon

如果 daemon 作为终端进程运行，关闭那个终端窗口即可。

如果你通过 `./scripts/install_macos_launch_agent.sh` 安装了 login daemon，先卸载它：

```bash
launchctl unload ~/Library/LaunchAgents/local.ai-monitor.daemon.plist
rm ~/Library/LaunchAgents/local.ai-monitor.daemon.plist
```

## 移除集成

**浏览器扩展：** 打开 `chrome://extensions`，移除 AI Monitor Browser Adapter。

**VS Code / Cursor 扩展：** 在 VS Code 或 Cursor 的扩展面板里卸载。

**终端 hooks：** Hooks 是项目级别的配置，位于你安装时指定的项目目录里的 `.claude/settings.json` 或 `.codex/hooks.json`，从这些文件中删除 AI Monitor 相关条目即可。

## 删除本地数据

预览将被删除的内容（不会实际删除）：

```bash
./scripts/uninstall_macos_app.sh --dry-run
```

删除所有数据：

```bash
./scripts/uninstall_macos_app.sh --yes
```

脚本会删除：

- `~/Library/Application Support/AI Monitor` — 配置和数据库
- `~/.ai-monitor` — API token
- `~/Library/Logs/AI Monitor` — daemon 日志
- `~/Library/Preferences/<bundle-id>.plist` — 如果存在
- `~/Library/LaunchAgents/local.ai-monitor.daemon.plist` — 如果已安装

按需保留部分数据：

```bash
./scripts/uninstall_macos_app.sh --yes --keep-data --keep-token --keep-logs
```

卸载脚本不会删除克隆下来的源码仓库目录，完成后可以手动删除。
