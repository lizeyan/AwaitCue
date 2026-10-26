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

Freezes all displays in memory, presents the global rectangle overlay, converts AppKit and ScreenCaptureKit coordinate systems, enforces one-window selection, and delegates browser identity to the Safari/Chromium relay.

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

Implements the Chromium Native Messaging length-prefixed JSON protocol and the token-authenticated loopback relay used by browser transports. Chromium reaches it through the browser-launched native host; Safari reaches it through the embedded native app extension.

Test seam: bytes in/out at the frame codec and typed messages at the protocol seam.

### AwaitCueSafariBridge

Validates Safari native messages, recursively rejects browser image fields, supplies the operating-system-confirmed Safari/Profile identity, and dispatches containing-app commands to the embedded Safari Web Extension. The App Group stores only the short-lived loopback descriptor; it never stores page evidence.

Test seam: DOM-only message in, authenticated relay payload or stable validation error out.

### AwaitCueRuntime

Coordinates condition evidence, minimum waits, shared interruption judgments, retries, lifecycle persistence, session wake behavior, and notification effects. Evidence stays on the current async stack and is never added to the persisted Hook.

Test seam: injected evidence, decisions, clock, and effect executor around a real `HookCoordinator`.

### BrowserExtension

Binds a Hook to a concrete Safari or Chromium tab, maps the native selected rectangle into the document viewport, and observes bounded DOM text, ARIA, semantic state classes, form/progress attributes, and relative coordinates. Browser Targets never capture or send pixels. A Canvas-, image-, or color-only region without readable semantics produces `no_semantic_content`, which is treated as insufficient evidence and therefore `uncertain`.

The Chromium native host and Safari native app extension attach operating-system browser identity to extension events. Selection and active-context queries accept a result only when that identity matches the requested browser and exactly one extension installation/Profile matches. Active-window privacy checks compare the same browser installation, window, tab, and host before and after the separate Appropriate to Interrupt screenshot. When Chromium sidebars make the exact horizontal page-viewport origin ambiguous, the extension expands the page DOM range to the smallest range covering every possible mapping. The creation UI discloses that adjacent page content may be included, and conflicting expanded evidence must remain `uncertain`. Browser UI and browser screenshots remain inaccessible to this path. Arc remains experimental.

Test seam: typed protocol, selection, and bounded page-evidence modules. Browser background/content entrypoints are thin adapters covered by build and real-browser smoke validation; shared evidence logic and both transport protocols retain explicit coverage gates.

### AwaitCueApp

Composes adapters, displays menu bar and settings UI, requests permissions, opens the global selection overlay, executes lifecycle effects, and owns process lifetime.

The executable composition layer is validated by warnings-as-errors builds and permission-gated macOS smoke tests. Reusable lifecycle, privacy, geometry, persistence, model, and relay behavior stays in library targets and is included in the automated coverage gate.

## Runtime flow

```text
Global selection
      ↓
Target resolver ──→ Safari/Chromium adapter / ScreenCaptureKit adapter
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

The menu bar app is the source of truth. When it exits, browser DOM observers and ordinary-App capture stop. On restart, persisted Hooks are loaded and Targets are resolved again. An ambiguous or missing Target becomes `targetUnavailable`; AwaitCue never silently binds a similar tab or window.
