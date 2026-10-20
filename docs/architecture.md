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

### AwaitCueModel

Adapts an OpenAI Responses API-compatible endpoint to three product decisions:

- prepare a Condition for user confirmation;
- evaluate a Condition against current evidence;
- evaluate whether current activity is appropriate to interrupt.

Test seam: typed request in, typed decision or typed transport/protocol error out.

### AwaitCuePersistence

Persists Hooks, Targets, minimal decisions, common Conditions, and compact feedback in SQLite. API keys are represented only by Keychain references.

Test seam: repository operations against a real temporary SQLite database.

### AwaitCueBrowserBridge

Implements the Chromium Native Messaging length-prefixed JSON protocol. It does not own browser observation behavior.

Test seam: bytes in/out at the frame codec and typed messages at the protocol seam.

### BrowserExtension

Binds a Hook to a concrete Chromium tab, maps the native selected rectangle into the document viewport, observes DOM changes, and manages explicit `tabCapture` sessions for pixel-only Targets.

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
- common Conditions and compact negative-interruption feedback;
- model base URL, model name, and Keychain reference.

Never persist:

- screenshots or capture frames;
- DOM source text;
- Base64 image payloads;
- complete model requests or responses;
- evidence strings copied from screen content;
- actual keystroke contents.

## Recovery

The menu bar app is the source of truth. When it exits, observers and capture streams stop. On restart, persisted Hooks are loaded and Targets are resolved again. An ambiguous or missing Target becomes `targetUnavailable`; AwaitCue never silently binds a similar tab or window.
