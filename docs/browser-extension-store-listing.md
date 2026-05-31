# Browser Extension Store Listing

Use this checklist when submitting `target/macos-dist/AI Monitor Browser Extension.zip` to the Chrome Web Store or a managed extension channel.

Chrome's developer documentation says the Privacy practices tab asks for the extension's single purpose, permission justifications, user-data disclosures, and a privacy policy URL. The Chrome Web Store Program Policies require disclosed data use to match the extension's actual behavior and privacy policy.

Official references:

- https://developer.chrome.com/docs/webstore/cws-dashboard-privacy
- https://developer.chrome.com/docs/webstore/program-policies/policies
- https://developer.chrome.com/docs/webstore/user_data

## Single Purpose

AI Monitor Browser Adapter reports supported AI website task state to the local AI Monitor desktop app so the user can see browser AI work in one local floating panel.

## Short Description

Reports supported AI web task state to the local AI Monitor desktop app.

## Detailed Description

AI Monitor Browser Adapter connects supported AI websites to the AI Monitor desktop app running locally on your Mac. It watches ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages for task state signals such as running, completed, failed, or waiting for input, then sends those events to your local AI Monitor daemon.

The extension uses a local API token copied from AI Monitor Settings. It sends events to `http://127.0.0.1:4318` by default and does not send data to an AI Monitor cloud service. Use the popup to paste or clear the local API token, test the connection, and open AI Monitor Settings for recovery.

## Permission Justifications

`storage`
: Stores the local daemon URL, local API token, workspace label, and last delivery status used by the extension popup.

`tabs`
: Reads the active tab title and URL for supported AI pages, identifies supported AI tabs, and lets AI Monitor return the user to the originating tab.

`alarms`
: Periodically refreshes supported tab presence so the local monitor can clear stale browser tasks after tabs close or Chrome restarts.

`scripting`
: Reinjects the content script into supported AI tabs after install, browser restart, or tab activation when Chrome did not load the script yet.

`http://127.0.0.1/*` and `http://localhost/*`
: Sends events to the AI Monitor daemon running locally on the user's computer.

Supported AI website host permissions
: Reads lightweight task-state signals only on ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages. X/Twitter permissions are limited to Grok paths.

## Data Disclosure Notes

Use conservative Chrome Web Store privacy disclosures. The extension handles:

- website content from supported AI pages, limited to task-state signals and short prompt/task labels;
- web browsing activity for supported AI pages, limited to URL and tab title needed to identify and reopen the task;
- authentication information, because the user may paste the local AI Monitor API token into the extension popup.

The extension does not collect financial, health, location, or payment data for its purpose. It does not sell data, use data for advertising, or send data to analytics services.

## Privacy Policy

Before publishing, host [browser-extension-privacy-policy.md](browser-extension-privacy-policy.md) on a public HTTPS URL controlled by the publisher, replace the contact section, set `AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL` to the same URL, and paste that URL into the Chrome Web Store Developer Dashboard.

The privacy policy URL must describe the same data handling and permission use disclosed in the store listing.
