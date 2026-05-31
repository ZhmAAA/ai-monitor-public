# AI Monitor 浏览器适配器隐私政策

[English](browser-extension-privacy-policy.md) | [简体中文](browser-extension-privacy-policy.zh-CN.md)

生效日期：2026-05-31

本政策适用于 AI Monitor Browser Adapter Chrome 扩展程序。

## 用途

本扩展程序的唯一用途：检测支持的 AI 网站上的任务状态，并将该状态上报给用户 Mac 上本地运行的 AI Monitor 应用。

支持的网站包括 ChatGPT、Claude、Gemini、Perplexity、Grok 和 GitHub coding-agent 页面。

## 处理的数据

本扩展程序可能在支持的 AI 网站上读取以下轻量级页面信息：

- 当前页面 URL 和标签页标题；
- 任务状态信号，例如运行中、已完成、失败或等待输入；
- 从页面提取的简短任务标题、步骤和状态消息；
- 最近一次用户提示的文本（仅用于为本地任务添加标签）；
- 用于返回原始标签页的浏览器标签页和窗口标识符。

本扩展程序仅在 Chrome 扩展存储中保存以下本地设置：

- 本地 AI Monitor daemon URL，默认为 `http://127.0.0.1:4318`；
- 用户粘贴的 AI Monitor 本地 API token；
- 可选的工作区标签；
- popup 中显示的最近一次本地传送状态。

## 本地传输

本扩展程序仅将任务事件发送到已配置的本地 AI Monitor daemon URL。默认 daemon URL 是用户自己电脑上的回环地址，扩展程序不会将数据发送到任何 AI Monitor 云服务。

AI Monitor 将收到的任务状态存储在用户的 Mac 本地。如果用户在桌面应用中配置了外部通知 provider，daemon 会在将通知内容发送到设备外部之前，按照其外部脱敏设置进行处理。

## 远程服务

本扩展程序不出售用户数据，不将用户数据用于广告，不向无关第三方传输浏览器数据。不进行任何分析、跟踪或广告请求。

本扩展程序仅访问支持的 AI 网站以检测用户本地监控器所需的任务状态，不修改提示词、回复、账户设置或页面内容。

## 权限

本扩展程序仅为完成任务监控目的而请求以下权限：

- `storage`：保存本地 daemon URL、本地 API token、工作区标签和最近一次传送状态；
- `tabs`：识别支持的 AI 标签页并附加返回标签的操作；
- `alarms`：定期刷新支持的标签页状态，以便在标签页关闭或 Chrome 重启后及时清除过期任务；
- `scripting`：在安装、浏览器重启或标签页激活后将 content script 重新注入支持的 AI 标签页；
- 支持的 AI 网站主机权限：仅在这些网站上检测任务状态（X/Twitter 权限仅限于 Grok 路径）；
- `127.0.0.1` 和 `localhost` 主机权限：将事件发送到用户本地运行的 AI Monitor daemon。

## 用户控制

用户可以在扩展 popup 中通过 `Clear Token` 清除已保存的本地 API token。用户可随时从 Chrome 中移除本扩展程序。用户也可以通过卸载指南卸载 AI Monitor 并删除本地数据。

## Chrome Web Store 限制性使用

本扩展程序对从 Chrome API 获取的信息的使用，仅限于提供和改进其单一用途：本地 AI 任务监控。AI Monitor 不将 Chrome API 数据用于广告、出售或与扩展无关的用户画像。

## 联系方式

请在将扩展程序提交到 Chrome Web Store 之前，将本节替换为发布者的支持邮箱或支持页面 URL。
