# AwaitCue

> **When it’s ready—and you are too.**

AwaitCue is an open-source macOS menu bar app that watches a selected app window or a specific Safari/Chromium browser tab, then brings it back to your attention only after the target is ready—and when interrupting you is appropriate.

It is not a timer that promises to interrupt at an exact deadline. A delayed Hook means “do not bring this back before this time.” After that minimum wait, AwaitCue still waits for an appropriate moment.

## Status

AwaitCue is in active early development. The repository currently focuses on proving the critical macOS, Safari, Chromium, decision-model, lifecycle, and privacy seams before polishing the complete product UI.

## Core ideas

- **Condition Hook** — watch a selected region until a natural-language condition is satisfied.
- **Delay Hook** — wait at least a chosen duration before the target may return to your attention.
- **Interruption-aware delivery** — notification delivery waits until the current screen context is appropriate to interrupt.
- **Explicit targets** — every Hook is bound to a selected app window or a specific Safari/Chromium tab.
- **User-owned model connection** — configure an OpenAI Responses API-compatible base URL, API key, and image-capable model.
- **Privacy by construction** — browser Targets use page text/ARIA/status attributes and never browser screenshots; ordinary macOS App screenshots and model request bodies are memory-only; API keys live in Keychain; telemetry is off.

## Planned user flow

1. Press the global shortcut.
2. Select one region inside one app window.
3. AwaitCue resolves the target:
   - Safari or Chromium tab and DOM/ARIA/status region, without browser screenshots; or
   - macOS window and normalized capture region through ScreenCaptureKit.
4. Create a Condition Hook or a Delay Hook.
5. Keep working while AwaitCue watches.
6. Receive a notification only when both the Hook and your attention are ready.

## Repository layout

```text
AwaitCue/
├── Sources/
│   ├── AwaitCueApp/             # SwiftUI/AppKit menu bar application
│   ├── AwaitCueCore/            # Domain types and deterministic lifecycle
│   ├── AwaitCueCapture/         # ScreenCaptureKit observation adapter
│   ├── AwaitCueSelection/       # Frozen multi-display selection and Target resolution
│   ├── AwaitCueModel/           # OpenAI Responses API adapter
│   ├── AwaitCuePersistence/     # SQLite persistence adapter
│   ├── AwaitCueBrowserBridge/   # Authenticated local relay and Native Messaging framing
│   ├── AwaitCueSafariBridge/    # Safari containing-app/native-extension messaging
│   └── AwaitCueRuntime/         # Observation, retry, decision, and notification orchestration
├── Sources/AwaitCueNativeHost/  # Chromium-launched stdio relay executable
├── Tests/                       # Swift Testing suites at public seams
├── BrowserExtension/            # Manifest V3 Chromium extension
├── SafariExtension/             # Embedded Safari Web Extension, Xcode target, and adapter tests
├── Scripts/                     # Build, package, coverage, and release helpers
├── docs/                        # Architecture, privacy, and contributor docs
└── .github/workflows/           # Required CI and release automation
```

## Requirements

- macOS 14 or newer
- Xcode 16.4 or newer
- Swift 6.0 or newer
- Node.js 24 LTS and npm 11 for Chromium and Safari WebExtension resources
- An image-capable model exposed through the OpenAI Responses API

## Build and test

Run all local checks:

```bash
./Scripts/check.sh
```

Run Swift tests only:

```bash
swift test
```

Run extension tests only:

```bash
npm --prefix BrowserExtension ci
npm --prefix BrowserExtension run coverage
npm --prefix SafariExtension test
```

Build the unsigned Safari `.appex` used by CI and local bundle assembly:

```bash
CONFIGURATION=debug ./Scripts/build-safari-extension.sh
```

Run the AppKit end-to-end window behavior tests:

```bash
./Scripts/run-macos-e2e.sh
```

On a local Mac whose terminal has Accessibility permission, the optional live layer exercises the real global shortcut, rectangle selection, a Calculator Target, close/reopen behavior, and an available Chromium Target without modifying TCC records:

```bash
./Scripts/run-macos-e2e.sh --live
```

For final local acceptance, require the installed Chromium extension instead of allowing that optional stage to skip:

```bash
./Scripts/run-macos-e2e.sh --live --require-chromium
```

Validate the fixed Decision benchmark corpus and scoring contract:

```bash
node --test Benchmarks/Decision/tests/*.test.mjs
node Scripts/run-decision-benchmark.mjs --dry-run
```

Live model quality runs are deliberately separate from required PR CI because they use a user-selected external provider and consume tokens. See [Benchmarks/Decision/README.md](Benchmarks/Decision/README.md) for the labeled corpus, accuracy/stability gates, and the manual GitHub Actions workflow.

`Scripts/package-release.sh` gives local ad-hoc builds a stable identifier-based designated requirement so macOS TCC permissions survive rebuilds. If you previously authorized a hash-based development build, remove its old Screen Recording entry and add the newly packaged app once.

Install the native host manifest for an unpacked Chromium extension:

```bash
AWAITCUE_CHROME_EXTENSION_ID=<chrome-id> \
AWAITCUE_ARC_EXTENSION_ID=<arc-id> \
./Scripts/install-native-host.sh /Applications/AwaitCue.app
```

The macOS settings window also links to the latest GitHub Release and opens the extension-management page of an installed Chrome, Edge, Arc, or Chromium app. Silent extension installation is not available to ordinary macOS apps; the user must confirm installation through the browser or load the unpacked release while the store listing is pending.

The Safari extension is embedded in the existing `AwaitCue.app`; there is no second helper app. After installing AwaitCue, the user must still enable **AwaitCue for Safari** and grant website access in Safari Settings. AwaitCue cannot silently enable the extension or grant host access. Build status, remaining signing work, and the real-Safari acceptance gate are tracked in [docs/safari-extension-readiness.md](docs/safari-extension-readiness.md).

Build the audited, deterministic Chrome Web Store archive:

```bash
npm --prefix BrowserExtension run package:store
```

Submission requirements, permission justifications, listing copy, and remaining external dashboard steps are tracked in [docs/chrome-web-store-readiness.md](docs/chrome-web-store-readiness.md). The public policy source is [docs/privacy-policy.md](docs/privacy-policy.md).

Unpacked extension IDs can differ by browser and profile, so the installer accepts a separate ID for Chrome, Edge, Chromium, and Arc. The native host only relays messages while the AwaitCue menu bar app is running and has published a private loopback token.

Arc support is experimental. AwaitCue safely rejects selections when a visible Arc sidebar, docked DevTools, or another wide asymmetric browser-chrome layout prevents the extension from proving the page viewport's screen origin; it never falls back to a guessed region. Hiding the sidebar may allow selection, but Chrome remains the reference browser for the current release.

The protected `master` branch requires every PR check to pass. Testable Swift library seams and shared TypeScript business modules are each required to remain at or above 90% coverage. Thin AppKit/TCC, native-host stdio, Safari native-extension entrypoints, and browser API entrypoints are excluded from automated coverage and must pass build plus real-environment smoke validation. Required CI builds the complete app bundle and verifies that the Safari `.appex` is embedded; enabling it and exercising a real Safari tab remains an explicit local/manual gate because CI cannot approve Safari website permissions on the user's behalf.

The default global Hook shortcut is `Control-Shift-Space` (`⌃⇧Space`). It avoids 1Password's common `Command-Shift-Space` shortcut and can be changed to another preset in AwaitCue settings. It freezes every display in memory, enforces a single-window selection, and then opens the Condition/Delay creation sheet.

## Branch policy

- All changes enter `master` through a GitHub Pull Request.
- Direct pushes, force pushes, and branch deletion are blocked.
- Required CI checks must pass before merge.
- Reviews must resolve all conversations before merge.
- Keep changes surgical and independently verifiable.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete development workflow.

## Privacy summary

AwaitCue observes highly sensitive screen context, so the implementation follows strict defaults:

- no browser screenshots at all, and no App screenshot or DOM history on disk;
- no telemetry or crash reporting in the first release;
- no keystroke contents or clipboard collection;
- no background operation after the menu bar app exits;
- user-configured bundle IDs and active Safari/Chromium hosts are checked locally before current-activity screenshots;
- every new custom API hostname requires explicit user confirmation;
- Responses API calls set `store: false`.

Read [docs/security-and-privacy.md](docs/security-and-privacy.md) for the detailed trust model.

## 中文简介

AwaitCue（候场）是一个开源 macOS 菜单栏应用。你可以在应用窗口、Safari 标签页或 Chromium 标签页中框选一个区域，创建条件 Hook 或延迟 Hook。浏览器 Target 只读取页面文字、ARIA 和状态属性，不上传浏览器截图。AwaitCue 负责观察目标，并且只在目标已经值得重新关注、同时你适合被打断时通知你。

它不是严格到点的倒计时，也不会在菜单栏应用退出后继续监控屏幕。

## License

AwaitCue is licensed under the [Apache License 2.0](LICENSE). Contributions submitted to this repository are accepted under the same license unless explicitly stated otherwise.
