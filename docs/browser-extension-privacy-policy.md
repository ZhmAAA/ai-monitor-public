# AI Monitor Browser Adapter Privacy Policy

[English](browser-extension-privacy-policy.md) | [简体中文](browser-extension-privacy-policy.zh-CN.md)

Effective date: 2026-05-31

This policy covers the AI Monitor Browser Adapter Chrome extension.

## Purpose

The extension has one purpose: detect task state on supported AI websites and report that state to the AI Monitor app running locally on the user's Mac.

Supported websites are ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages.

## Data Handled

The extension may read lightweight page information on supported AI websites:

- current page URL and tab title;
- visible task status signals, such as running, completed, failed, or waiting for input;
- short task title, step, and status messages derived from the page;
- the most recent user prompt text when needed to label the local task;
- browser tab and window identifiers used to return the user to the original tab.

The extension stores only local settings in Chrome extension storage:

- local AI Monitor daemon URL, defaulting to `http://127.0.0.1:4318`;
- AI Monitor local API token pasted by the user;
- optional workspace label;
- last local delivery status shown in the popup.

## Local Transfer

The extension sends task events only to the configured local AI Monitor daemon URL. The default daemon URL is a loopback address on the user's own computer. The extension does not send data to an AI Monitor cloud service.

AI Monitor stores received task state locally on the user's Mac. If the user configures external notification providers in the desktop app, the daemon applies its external redaction settings before sending notification content outside the computer.

## Remote Services

The extension does not sell user data, does not use user data for advertising, and does not transfer browser data to unrelated third parties. It does not make analytics, tracking, or advertising requests.

The extension accesses supported AI websites only to detect task state for the user's local monitor. It does not modify prompts, replies, account settings, or page content.

## Permissions

The extension requests permissions only for its task-monitoring purpose:

- `storage`: save local daemon URL, local API token, workspace label, and last delivery status;
- `tabs`: identify supported AI tabs and attach a return-to-tab action;
- `alarms`: periodically refresh supported tab presence so closed or stale tasks can be reconciled;
- `scripting`: reinject the content script into supported AI tabs after install, browser restart, or tab activation;
- host permissions for supported AI websites: detect task state only on those sites, with X/Twitter access limited to Grok paths;
- host permissions for `127.0.0.1` and `localhost`: send events to the user's local AI Monitor daemon.

## User Control

Users can clear the stored local API token from the extension popup with `Clear Token`. Users can remove the extension from Chrome at any time. Users can also uninstall AI Monitor and remove local data with the uninstall guide bundled in the macOS DMG.

## Chrome Web Store Limited Use

The extension's use of information received from Chrome APIs is limited to providing and improving its single purpose: local AI task monitoring. AI Monitor does not use Chrome API data for advertising, sale, or unrelated user profiling.

## Contact

Replace this section with the publisher's support email or support URL before submitting the extension to the Chrome Web Store.
