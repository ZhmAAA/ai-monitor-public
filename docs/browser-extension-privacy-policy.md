# AI Monitor Browser Extension Privacy Policy

Effective date: 2026-05-31

This policy covers the AI Monitor Browser Extension.

## Purpose

The extension detects task state on supported AI websites and reports that state to the AI Monitor app running locally on your Mac.

Supported websites include ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages.

## Data Handled

The extension may read lightweight page information on supported AI websites:

- Current page URL and tab title.
- Visible task status signals, such as running, completed, failed, or waiting for input.
- Short task title, step, and status messages derived from the page.
- Browser tab and window identifiers used to return you to the original tab.

The extension stores only local settings in Chrome extension storage:

- Local AI Monitor daemon URL.
- AI Monitor local API token pasted by you.
- Optional workspace label.
- Last local delivery status shown in the popup.

## Local Transfer

The extension sends task events only to the configured local AI Monitor daemon URL. The default daemon URL is a loopback address on your own computer.

The extension does not send data to an AI Monitor cloud service.

## Remote Services

The extension does not sell user data, does not use user data for advertising, and does not transfer browser data to unrelated third parties.

The extension accesses supported AI websites only to detect task state for your local monitor. It does not modify prompts, replies, account settings, or page content.

## Permissions

The extension requests permissions for task monitoring:

- `storage`: save local settings.
- `tabs`: identify supported AI tabs and attach return-to-tab actions.
- `alarms`: refresh supported tab state.
- `scripting`: restore content scripts after install, browser restart, or tab activation.
- Supported website permissions: detect task state only on those sites.
- `127.0.0.1` and `localhost`: send events to your local AI Monitor daemon.

## User Control

You can clear the stored local API token from the extension popup with `Clear Token`. You can remove the extension from Chrome at any time.

You can also uninstall AI Monitor and remove local data with the bundled uninstall guide.
