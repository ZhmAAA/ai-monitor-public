# AI Monitor Chrome Extension

This Manifest V3 extension watches supported AI web apps and sends task state events to the local AI Monitor daemon.

## Supported pages

- ChatGPT
- Claude
- Gemini
- Perplexity
- Grok
- GitHub

## Public install

Public users should install AI Monitor's Chrome Web Store or managed extension from the release channel. The public macOS DMG `README.txt` and `RELEASE_MANIFEST.json` record the browser extension install URL for that release.

1. Open AI Monitor from `/Applications`.
2. In AI Monitor Settings, click `Copy API token`.
3. In AI Monitor Settings, click `Open browser install link`, or click `Copy browser install link` if you need to paste the URL into a managed browser.
4. Open the extension popup, paste the API token, and click `Test`.
5. If the popup says the daemon is offline or needs a token later, click `Open AI Monitor Settings` in the popup.

Do not use `Load unpacked` for public installs. Developer Mode is for source checkouts and internal testing only.

Use `Clear Token` in the popup when rotating the local API token or removing the extension from a shared browser profile.

## Development install

1. Start AI Monitor from the macOS app menu bar, or start the daemon from a source checkout:

   ```bash
   cd /path/to/ai-monitor
   cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
   ```

2. In AI Monitor Settings, click `Copy API token`. If you are running only the daemon from source, copy the token from `~/.ai-monitor/api-token` unless you set `AI_MONITOR_API_TOKEN` yourself.

3. Open Chrome:

   ```txt
   chrome://extensions
   ```

4. Enable Developer Mode.
5. Click `Load unpacked`.
6. Select:

   ```txt
   /path/to/ai-monitor/integrations/browser-extension/chrome
   ```

7. Open the extension popup, paste the API token, and click `Test`.

## Packaged extension

The macOS package script also creates:

```txt
target/macos-dist/AI Monitor Browser Extension.zip
```

That zip has `manifest.json` at the root and excludes detector fixtures and development files. Use it for Chrome Web Store submission or managed internal rollout, not as the ordinary public install path. For internal testing only, unzip it and load the unzipped folder with Chrome Developer Mode.

Before Chrome Web Store submission, prepare the privacy and listing fields from:

```txt
docs/browser-extension-store-listing.md
docs/browser-extension-privacy-policy.md
```

## Event mapping

The extension sends:

- `session_name`: cleaned tab title, such as `生成图片`.
- `window_title`: full tab title plus `Chrome`.
- `source`: `chatgpt-web`, `claude-web`, `gemini-web`, `perplexity-web`, `grok-web`, or `github-web`.
- `status`: `running`, `completed`, `failed`, or `waiting_for_input`.

Detection is heuristic in this milestone. The content script prefers visible stop buttons, continue buttons, retry/error text, and response text stability. GitHub is only reported when the page has explicit Copilot or coding-agent signals; ordinary repositories, profiles, issues, and PRs are ignored.

## Detector fixtures

Run the local fixture harness before changing `content.js` selectors:

```bash
./scripts/test_browser_detectors.sh
```

Fixtures live in `integrations/browser-extension/chrome/test/fixtures` and currently cover ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub Copilot-style pages.
