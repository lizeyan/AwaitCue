# AwaitCue

> **When it’s ready—and you are too.**

AwaitCue is an open-source macOS menu bar app that watches a selected app window or Chromium browser tab, then brings it back to your attention only after the target is ready—and when interrupting you is appropriate.

It is not a timer that promises to interrupt at an exact deadline. A delayed Hook means “do not bring this back before this time.” After that minimum wait, AwaitCue still waits for an appropriate moment.

## Status

AwaitCue is in active early development. The repository currently focuses on proving the critical macOS, Chromium, decision-model, lifecycle, and privacy seams before polishing the complete product UI.

## Core ideas

- **Condition Hook** — watch a selected region until a natural-language condition is satisfied.
- **Delay Hook** — wait at least a chosen duration before the target may return to your attention.
- **Interruption-aware delivery** — notification delivery waits until the current screen context is appropriate to interrupt.
- **Explicit targets** — every Hook is bound to a selected app window or a specific Chromium tab.
- **User-owned model connection** — configure an OpenAI Responses API-compatible base URL, API key, and image-capable model.
- **Privacy by construction** — screenshots, DOM text, capture frames, and model request bodies are memory-only; API keys live in Keychain; telemetry is off.

## Planned user flow

1. Press the global shortcut.
2. Select one region inside one app window.
3. AwaitCue resolves the target:
   - Chromium tab and DOM region, with `tabCapture` when pixels are required; or
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
│   ├── AwaitCueModel/           # OpenAI Responses API adapter
│   ├── AwaitCuePersistence/     # SQLite persistence adapter
│   └── AwaitCueBrowserBridge/   # Chromium Native Messaging framing
├── Tests/                       # Swift Testing suites at public seams
├── BrowserExtension/            # Manifest V3 Chromium extension
├── Scripts/                     # Build, package, coverage, and release helpers
├── docs/                        # Architecture, privacy, and contributor docs
└── .github/workflows/           # Required CI and release automation
```

## Requirements

- macOS 14 or newer
- Xcode 26 or newer for the current development toolchain
- Swift 6.0 or newer
- Node.js 24 LTS and npm 11 for the Chromium extension
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
```

The protected `master` branch requires every PR check to pass. Swift and TypeScript coverage are each required to remain at or above 90%.

## Branch policy

- All changes enter `master` through a GitHub Pull Request.
- Direct pushes, force pushes, and branch deletion are blocked.
- Required CI checks must pass before merge.
- Reviews must resolve all conversations before merge.
- Keep changes surgical and independently verifiable.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete development workflow.

## Privacy summary

AwaitCue observes highly sensitive screen context, so the implementation follows strict defaults:

- no screenshot or DOM history on disk;
- no telemetry or crash reporting in the first release;
- no keystroke contents or clipboard collection;
- no background operation after the menu bar app exits;
- excluded apps and hosts never send screenshots to the model;
- every new custom API hostname requires explicit user confirmation;
- Responses API calls set `store: false`.

Read [docs/security-and-privacy.md](docs/security-and-privacy.md) for the detailed trust model.

## 中文简介

AwaitCue（候场）是一个开源 macOS 菜单栏应用。你可以在应用窗口或 Chromium 标签页中框选一个区域，创建条件 Hook 或延迟 Hook。AwaitCue 负责观察目标，并且只在目标已经值得重新关注、同时你适合被打断时通知你。

它不是严格到点的倒计时，也不会在菜单栏应用退出后继续监控屏幕。

## License

The open-source license will be finalized before the first merge. Apache-2.0 is the current recommendation; see the open project discussion before contributing copyrighted code.
