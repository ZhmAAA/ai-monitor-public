# Troubleshooting

Use this guide when AI Monitor opens but tasks do not appear, notifications do not work, or an integration cannot connect.

## First Run

Settings should open automatically the first time you launch AI Monitor.

If it does not, open AI Monitor from the menu bar and choose Settings.

Click `Test connection`. If it says offline, click `Start daemon`, then test again.

## Browser Extension Reports 401

1. Open AI Monitor Settings.
2. Click `Copy API token`.
3. Open the browser extension popup.
4. Paste the token.
5. Click `Save`, then `Test`.

## Browser Tasks Do Not Appear

- Confirm the extension popup says the daemon is online.
- Confirm the API token was saved in the extension popup.
- Reload the AI website after installing or updating the extension.
- Confirm the page is one of the supported sites: ChatGPT, Claude, Gemini, Perplexity, Grok, or GitHub coding-agent pages.

## Terminal Tasks Do Not Appear

- Confirm Node.js is installed.
- Reinstall the terminal integrations from the downloaded integration package.
- Run `Test connection` in AI Monitor Settings before checking hooks.
- In Codex CLI, review and trust the AI Monitor hooks if prompted.

## IDE Tasks Do Not Appear

- In VS Code or Cursor, run `AI Monitor: Send Test Event`.
- If delivery fails, run `AI Monitor: Open Desktop Settings`.
- Click `Test connection` in Settings.
- If you see an auth warning, copy the API token from Settings and paste it into the extension setting.

## Clicking A Task Does Not Focus The App

The first time AI Monitor returns to a browser, editor, or terminal window, macOS may ask whether AI Monitor can control that app. Choose `Allow`.

If you denied the prompt before, open System Settings -> Privacy & Security -> Automation, then allow AI Monitor to control the relevant app.

## Notifications Do Not Appear

- Allow notifications for AI Monitor in macOS System Settings.
- Keep local clickable notifications enabled in AI Monitor Settings.
- Third-party providers are disabled by default and must be configured before use.

## Clean Reinstall

See [Uninstall](uninstall.md) for cleanup steps.
