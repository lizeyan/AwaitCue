# Architecture

## Objective

AwaitCue separates two independent decisions:

1. Is the selected Target ready for attention?
2. Is the person currently appropriate to interrupt?

The deterministic runtime owns time, state transitions, retries, persistence, and notification effects. A model may classify evidence, but it never mutates Hook state or performs an external action directly.

## Modules and seams

### AwaitCueCore

Owns domain types and the deterministic Hook lifecycle. It has no dependency on UI, ScreenCaptureKit, networking, SQLite, or browser APIs.

Test seam: public lifecycle events in, `HookTransition` out.

### AwaitCueCapture

Observes macOS windows through ScreenCaptureKit and converts normalized Target regions to concrete pixel crops.

Test seam: observation request in, availability plus image evidence out.

### AwaitCueSelection

Freezes all displays in memory, presents the global rectangle overlay, converts AppKit and ScreenCaptureKit coordinate systems, enforces one-window selection, and delegates browser identity to the Chromium relay.

Test seam: display frames and drag geometry in, one exact `HookTarget` or a stable selection error out. AppKit overlay and TCC-bound screenshot glue are covered by manual desktop smoke tests rather than counted as automated business coverage.

### AwaitCueModel

Adapts an OpenAI Responses API-compatible endpoint to three product decisions:

- prepare a Condition for user confirmation;
- evaluate a Condition against current evidence;
- evaluate whether current activity is appropriate to interrupt.

Test seam: typed request in, typed decision or typed transport/protocol error out.

### AwaitCuePersistence

Persists Hooks, Targets, and minimal decisions in SQLite, and stores the model API key directly in macOS Keychain. Model endpoint settings and local exclusion rules use `UserDefaults`.

Test seam: repository operations against a real temporary SQLite database.

### AwaitCueBrowserBridge

Implements the Chromium Native Messaging length-prefixed JSON protocol and a token-authenticated loopback relay between the menu bar app and Chromium-launched native host.

Test seam: bytes in/out at the frame codec and typed messages at the protocol seam.

### AwaitCueRuntime

Coordinates condition evidence, minimum waits, shared interruption judgments, retries, lifecycle persistence, session wake behavior, and notification effects. Evidence stays on the current async stack and is never added to the persisted Hook.

Test seam: injected evidence, decisions, clock, and effect executor around a real `HookCoordinator`.

### BrowserExtension

Binds a Hook to a concrete Chromium tab, maps the native selected rectangle into the document viewport, observes DOM changes, and manages explicit `tabCapture` sessions for pixel-only Targets.

The native host adds the launching browser's operating-system bundle identity to extension events. Selection and active-host queries accept a result only when that identity matches the requested browser and exactly one extension installation responds. Arc is experimental: layouts with a visible wide sidebar or docked DevTools are rejected because Chromium exposes no trustworthy absolute viewport origin for those asymmetric layouts.

Test seam: typed extension messages and DOM fixtures, not Chrome implementation details.

### AwaitCueApp

Composes adapters, displays menu bar and settings UI, requests permissions, opens the global selection overlay, executes lifecycle effects, and owns process lifetime.

## Runtime flow

```text
Global selection
      ↓
Target resolver ──→ Chromium adapter / ScreenCaptureKit adapter
      ↓
Evidence change
      ↓
Condition decision ──→ Hook lifecycle ──→ waiting for interruption
                                             ↓
Active-window evidence ──→ interruption decision
                                             ↓
                                      notification effect
```

## Persistence boundary

Persist:

- Hook definitions and lifecycle state;
- Target locators;
- last decision enum, timestamp, and confidence;
- model base URL, model name, and local exclusion rules in `UserDefaults`;
- the model API key in macOS Keychain.

Never persist:

- screenshots or capture frames;
- DOM source text;
- Base64 image payloads;
- complete model requests or responses;
- evidence strings copied from screen content;
- actual keystroke contents.

## Recovery

The menu bar app is the source of truth. When it exits, observers and capture streams stop. On restart, persisted Hooks are loaded and Targets are resolved again. An ambiguous or missing Target becomes `targetUnavailable`; AwaitCue never silently binds a similar tab or window.
