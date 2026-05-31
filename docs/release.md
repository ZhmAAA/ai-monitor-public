# macOS Release

AI Monitor can build a local ad-hoc package for testing, but an internet-distributed package for ordinary users must be signed with a Developer ID Application certificate and notarized by Apple.

The packaged macOS app declares `LSMinimumSystemVersion` from `AI_MONITOR_MACOS_MIN_VERSION`, which defaults to `13.0`. The build script also sets `MACOSX_DEPLOYMENT_TARGET` and the Swift compile target to that version so building on a newer macOS host does not accidentally produce a binary that only launches on that host's OS generation.

Public release builds are universal for Apple Silicon and Intel Macs. In `AI_MONITOR_RELEASE=1` mode, the build and verifier expect `AI_MONITOR_MACOS_ARCHS="arm64 x86_64"` and require both Rust targets:

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

## One-time setup

1. Install a valid `Developer ID Application` certificate in the macOS login keychain.
2. Store notary credentials:

```bash
xcrun notarytool store-credentials ai-monitor-notary \
  --apple-id you@example.com \
  --team-id TEAMID1234 \
  --password app-specific-password
```

3. Generate a private ignored release environment file and replace every placeholder with the real publisher, signing, notary, and browser-extension install values:

```bash
./scripts/init_macos_release_env.sh
${EDITOR:-vi} .env.release.local
```

## Release build

### Private test download

You can send a direct download to internal testers before Apple signing and notarization are ready:

```bash
./scripts/stage_private_test_release.sh
```

Share the files in `target/macos-public-release` only with testers who expect a development build. This preview is ad-hoc signed, not notarized, and may trigger macOS Gatekeeper warnings such as an unidentified-developer prompt. It is useful for quick feedback, but it is not the ordinary-user public release path.

### Public ordinary-user download

Check the release machine first:

```bash
./scripts/check_macos_release_prereqs.sh
```

`scripts/release_macos_app.sh` sets `AI_MONITOR_CHECK_NOTARY_ONLINE=1` by default so the stored notary profile or Apple ID notary credential environment variables are verified with Apple before packaging. Set it explicitly only if you are running lower-level prereq checks outside the public release script.

```bash
set -a
. ./.env.release.local
set +a

./scripts/check_macos_release_prereqs.sh
./scripts/release_macos_app.sh
```

`scripts/release_macos_app.sh` forces release mode, turns on online notary profile validation by default, reruns prerequisite checks, builds, Developer ID signs, notarizes and staples the app bundle, packages the stapled app into the DMG, notarizes and staples the DMG, validates the stapled tickets with `xcrun stapler validate`, verifies the artifacts in release mode, and stages the public upload set from `RELEASE_MANIFEST.json`. Use `./scripts/release_macos_app.sh --check-only` when you only want the public release gate without packaging.
Set `AI_MONITOR_CODESIGN_IDENTITY` to the exact `Developer ID Application: ...` identity shown by `security find-identity -v -p codesigning`; merely having a certificate in the keychain is not enough for the public release script.

`scripts/init_macos_release_env.sh` writes `.env.release.local` with `0600` permissions, fills `AI_MONITOR_CODESIGN_IDENTITY` when it can detect a local `Developer ID Application` certificate, and leaves publisher, bundle, browser-extension, and notary placeholders for you to confirm. The template includes `AI_MONITOR_BUNDLE_ID`, `AI_MONITOR_COPYRIGHT`, `AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL`, `AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL`, `AI_MONITOR_CODESIGN_IDENTITY`, `AI_MONITOR_NOTARY_PROFILE`, the Apple ID notary fallback variables, app version/build values, and release-mode switches. Replace every example publisher value with the real app identity before a public release. The release-mode scripts reject `local.*`, `example.*`, and `yourcompany` placeholder bundle identifiers, plus development/example copyright text.

The staged release artifact for ordinary users is:

```txt
target/macos-public-release/AI Monitor.dmg
```

`target/macos-dist/AI Monitor.dmg` is the packaged source artifact produced by the build; publish the staged copy after `scripts/stage_public_release.sh` has verified the manifest and checksums.

The DMG includes `README.txt` with install, first-run, integration, support, and uninstall notes, `LICENSE.txt` with the AI Monitor MIT license, `THIRD-PARTY-NOTICES.txt` generated from bundled dependency metadata, `PRIVACY.txt` with local storage, permission, and external notification defaults, `TROUBLESHOOTING.txt` with offline first-run and integration recovery steps, `UNINSTALL.txt` with cleanup steps users can keep after deleting the app, and `UNINSTALL.command`, a safe cleanup helper that previews paths first and requires typing `DELETE` before removal. The app bundle also includes `LICENSE.txt` and `THIRD-PARTY-NOTICES.txt`, which Settings exposes through `Copy license notices`, `first-run-guide.txt`, which Settings exposes through `Copy setup guide`, `browser-extension-install-url.txt`, which Settings exposes through `Open browser install link` and `Copy browser install link`, `troubleshooting-guide.txt`, which Settings exposes through `Copy troubleshooting guide`, `privacy-notice.txt`, which Settings exposes through `Copy privacy notice`, and `uninstall-guide.txt`, which Settings exposes through `Copy uninstall guide`. Public release builds render the exact `AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL` into the DMG `README.txt`, bundled `first-run-guide.txt`, and bundled browser install link resource so the copied setup guide and direct Settings buttons remain useful after the DMG is ejected. Keep [macos-dmg-readme.txt](macos-dmg-readme.txt), [macos-app-setup-guide.txt](macos-app-setup-guide.txt), [macos-troubleshooting-guide.txt](macos-troubleshooting-guide.txt), [macos-privacy-notice.txt](macos-privacy-notice.txt), and [macos-uninstall-guide.txt](macos-uninstall-guide.txt) aligned with current Settings actions and defaults.

The app archive is:

```txt
target/macos-dist/AI Monitor.zip
```

This zip is for automation and internal deployment workflows. Do not publish it as the ordinary-user macOS installer unless that workflow has its own notarization and Gatekeeper validation. The release manifest marks this artifact as `automation_only_not_public_installer`.

The browser adapter artifact is:

```txt
target/macos-dist/AI Monitor Browser Extension.zip
```

Use that zip for Chrome Web Store submission or managed internal extension rollout. Public browser users should install a store/managed extension from `AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL`; developer-mode `Load unpacked` is only acceptable for internal testing. Release prereqs reject missing, local, or placeholder browser extension install URLs so the DMG README, bundled setup guide, and manifest can point ordinary users at the exact browser install path. Release prereqs also require `AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL`, the public HTTPS privacy policy URL used in the Chrome Web Store listing.
Before submitting to the Chrome Web Store, host [browser-extension-privacy-policy.md](browser-extension-privacy-policy.md) at a public HTTPS URL and fill the store listing from [browser-extension-store-listing.md](browser-extension-store-listing.md).

The IDE extension artifact is:

```txt
target/macos-dist/AI Monitor IDE Extension.vsix
target/macos-dist/AI Monitor IDE Extension.zip
```

Use the VSIX when VS Code or Cursor users need IDE task reporting without a source checkout. The zip contains the same no-build extension files as an unpacked-folder fallback. JetBrains remains a source-only adapter until a signed plugin artifact is added.

The terminal integration artifact is:

```txt
target/macos-dist/AI Monitor Terminal Integrations.zip
```

Use it when terminal/agent users need Claude Code, Codex CLI, shell command, or Superset adapters without a source checkout. These adapters require Node.js to be installed on the user's machine.
The zip includes `Install AI Monitor Terminal Integrations.command` at the root for ordinary users and `integrations/terminal/install-terminal-integrations.command` for scripted installs; give users one of those wrappers instead of a raw `node ...` command so missing Node.js is explained before the installer runs.
The packaged and lower-level hook installers must reject missing project paths with a clear error instead of creating project directories from typos.

The checksum manifest is:

```txt
target/macos-dist/SHA256SUMS.txt
```

The machine-readable release manifest is:

```txt
target/macos-dist/RELEASE_MANIFEST.json
```

Publish it with the artifacts. Users and maintainers can verify downloads with:

```bash
cd target/macos-dist
shasum -a 256 -c SHA256SUMS.txt
```

`SHA256SUMS.txt` covers the public artifacts and `RELEASE_MANIFEST.json`. The manifest lists artifact versions, sizes, checksums, roles, target audience, publishability, and user-facing usage notes for the downloadable app, browser, IDE, and terminal packages; it intentionally does not include its own checksum to avoid self-reference.

The manifest records the app's signing mode, hardened runtime status, Apple Events entitlement status, notarization requirement, app-bundle and DMG stapled ticket validation, Gatekeeper assessment requirements, CPU architectures, DMG root support files, the safe uninstall command confirmation behavior, and artifact checksums. The release verifier checks those manifest fields against the app bundle, DMG contents, and verifier mode.

The public upload directory is:

```txt
target/macos-public-release
```

It is created by `scripts/stage_public_release.sh`, which reads `distribution.publish_with_release` from `RELEASE_MANIFEST.json`, copies only artifacts marked `publish=true` plus the checksum and manifest files, writes `PUBLIC_RELEASE_README.txt`, and verifies the staged checksums. Upload from this directory instead of uploading every file in `target/macos-dist`. The staging script refuses manifests where `release_mode` is not `true`; set `AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE=1` only when you intentionally want a local staging preview from an ad-hoc development package, and never upload that preview to ordinary users.

The release script refuses to run in `AI_MONITOR_RELEASE=1` mode unless Developer ID signing, notarization, and universal macOS architectures are configured. Release mode also rejects `AI_MONITOR_SKIP_CODESIGN=1` and `AI_MONITOR_SKIP_NOTARIZE=1`. Local development builds without `AI_MONITOR_RELEASE=1` are ad-hoc signed and should not be distributed as a public release.

Packaging signs the bundled daemon executable explicitly with hardened runtime, then signs the app bundle with the Apple Events automation entitlement from `apps/desktop-macos/AI-Monitor.entitlements`. That entitlement is required for click-to-return behavior that activates browser and terminal windows through AppleScript.

Before publishing, verify the installed-user cleanup path in [uninstall.md](uninstall.md). The app should leave no required state in the source checkout, and the release verifier should pass without local user paths, private IDs, AppleDouble metadata, extension test fixtures, or development-only `repo-root.txt` files.

The release verifier also runs `cargo test --workspace`, then checks the bundled `default.toml`: API auth must stay enabled, external prompt/reply/workspace redaction must stay enabled, the ordinary-user default provider list must contain only the enabled desktop provider, and default notification rules may only send to `desktop`. It also checks that the bundled first-run guide covers API token setup, optional Desktop app observer permission, and support diagnostics without including token, Keychain, or provider-secret examples.

The verifier also guards the macOS token path: the daemon must tighten existing token-file permissions to `0600`, the app must launch the daemon with `--api-token-file`, let `Copy API token` create the token file when needed, migrate legacy UserDefaults tokens to the token file, and must not write API tokens into UserDefaults, a LaunchAgent plist, or a child-process environment.

In release mode, the verifier validates the stapled app-bundle and DMG tickets with `xcrun stapler validate`, runs Gatekeeper assessment on the DMG with `spctl --type open`, validates the app bundle copied into the DMG, and assesses the mounted app bundle with `spctl --type execute`.

Manual smoke test for first-run support:

1. Mount the DMG, drag `AI Monitor.app` into `/Applications`, then open it from Applications.
2. Confirm Settings opens automatically on first launch, then click `Copy setup guide`; confirm it does not include the API token or provider secrets.
3. Also test the common mistake path: open the app directly from the mounted DMG, quit, drag it into `/Applications`, and reopen it. Settings should open again because running from a transient location must not mark first-run setup as completed.
4. Confirm the monitor shows `Daemon starting automatically` when the local daemon is offline.
5. Click `Test connection`; it should report the daemon online. If it reports offline, click `Start daemon` and test again.
6. Click `Open browser install link` and confirm it opens the configured store or managed-extension URL; use `Copy browser install link` for managed-browser install flows. Click `Copy API token` on a clean install before and after the daemon is online; it should create or reuse `~/.ai-monitor/api-token`, copy the token, and preserve `0600` permissions. Paste it into the browser extension popup and click `Test`, then click `Open AI Monitor Settings` in the popup and confirm it opens the desktop Settings panel via `ai-monitor://settings`.
7. Confirm `Provider Health` shows `No external providers configured` on a clean install, without making a daemon health request fail while the daemon is still starting. After adding a provider, confirm health loads without exposing secrets and disabled or missing providers are explained inline.
8. Install `AI Monitor IDE Extension.vsix` in VS Code or Cursor with `Extensions: Install from VSIX...`, run `AI Monitor: Send Test Event`, and confirm it can report without requiring a source checkout. Force a daemon/token failure once and confirm `AI Monitor: Open Desktop Settings` opens Settings through `ai-monitor://settings`. Also unzip `AI Monitor IDE Extension.zip` and confirm the unpacked-folder fallback contains only `package.json`, `extension.js`, and `README.md`.
9. Click `Open logs`, `Open data folder`, `Open browser install link`, `Copy browser install link`, `Copy troubleshooting guide`, `Copy license notices`, `Copy privacy notice`, `Copy uninstall guide`, and `Copy diagnostics` to confirm support actions work without exposing secrets and include app version, bundle identifier, minimum macOS version, current macOS version, browser install-link configured state, login daemon label, login daemon loaded/running state, token-file existence, and token-file permissions.
10. Confirm the login daemon is installed only after the app has been dragged into `/Applications`, not while it is running from the mounted DMG, and that installing it after `Start daemon` hands off the app-started daemon to launchd instead of leaving two daemon processes fighting for the same port.
11. With the login daemon running, click `Start daemon` again and confirm it reports the running login daemon instead of starting a second local daemon.
12. Quit AI Monitor after starting the daemon without installing the login daemon, then confirm the app-started daemon stops. Install the login daemon when integrations should keep working after app quit or after login.
13. Click a browser-backed and terminal-backed task, accept the macOS Automation prompt, and confirm the expected app comes to the front.
14. Confirm macOS notification permission is not requested immediately on app launch; it should be requested only when AI Monitor first needs to show a local alert and Local clickable notifications is enabled.
15. Enable `Desktop app observer`, click `Request Accessibility`, and confirm diagnostics include the expected `accessibility_trusted` state.

Also run through [troubleshooting.md](troubleshooting.md) after a clean install to make sure the user-facing recovery steps match the current build.
