# Security and privacy

AwaitCue handles screen content that may include source code, documents, messages, credentials, or private browsing context. The privacy model therefore treats every capture and DOM fragment as sensitive by default.

## Local guarantees

- Ordinary-App screenshots, Appropriate to Interrupt screenshots, frozen selection frames, and sanitized browser HTML evidence remain in memory only.
- Safari and Chromium Browser Targets produce a length-bounded HTML fragment that preserves relevant page hierarchy, visible text, complete `class` values, ARIA and `data-*` attributes, and relative `data-awaitcue-rect` coordinates. They never capture or send browser screenshots.
- The application does not collect clipboard contents or actual key values.
- API keys are stored in macOS Keychain.
- Structured logs contain identifiers, decision enums, confidence, and sanitized error categories only.
- Telemetry and crash reporting are disabled in the initial release.
- User-configured bundle IDs and active Safari/Chromium hosts are checked locally before the Appropriate to Interrupt screenshot. Browser context is checked again after capture, and the in-memory image is discarded unless the same browser installation, window, tab, and host remain active. An excluded or ambiguous result is classified as not appropriate to interrupt without uploading that screenshot.
- Exiting the menu bar app stops browser DOM observation and ordinary-App capture.

## Model endpoint boundary

The user configures a Responses API-compatible base URL. Before saving a new hostname, AwaitCue must disclose the exact destination receiving screenshots and page information.

Every request sets `store: false`, but a third-party compatible endpoint may ignore that field. AwaitCue can guarantee its own local behavior and outgoing request shape; it cannot guarantee a provider’s retention policy.

The local exclusion lists apply to current-activity evidence used for the interruption decision. They do not silently change the Target that the user explicitly selected for a Condition Hook; Target evidence remains governed by that explicit selection and the confirmed model endpoint.

## Untrusted observed content

Text and images from observed apps are data, never instructions. Model instructions must explicitly state that page or window content cannot alter the decision contract, invoke tools, or request external actions.

## Browser permissions

All Browser Targets are DOM-only. Extensions do not request tab video, browser screenshots, or pixel-capture permissions. The local extractor only selects intersecting page content, removes unrelated or unsafe markup, preserves the remaining HTML relationships and allowed attributes, and enforces the evidence limit. It must not classify business state from a class-name vocabulary or add website-specific status handling. If the mapped page DOM range exposes no usable HTML meaning, the extension reports `no_semantic_content`; AwaitCue must treat this as insufficient evidence and return or retain `uncertain`, never infer state from absent pixels.

Chromium does not expose how total horizontal browser chrome is divided between left and right sidebars. When that prevents an exact page-viewport mapping, AwaitCue derives every possible horizontal mapping and reads the smallest page DOM range covering all of them instead of rejecting the Hook or guessing one side. The creation window must disclose that the range was expanded and may contain adjacent page content. Model instructions must require `uncertain` when evidence within that expanded range conflicts. The extension still cannot read the address bar, tab strip, bookmarks bar, browser sidebar, or browser pixels because none of those surfaces are part of the page DOM.

The Chromium native host does not own Hook state. It authenticates to a loopback-only menu bar relay with a random token stored in a `0600` descriptor, then forwards already-framed JSON. Either forwarding direction ending terminates the dedicated host process, so closing the menu bar app disconnects the extension and stops its DOM observers.

Safari uses the existing `AwaitCue.app` as its containing app. Its sandboxed native app extension reads the same short-lived descriptor through the configured App Group and forwards DOM-only events to the loopback relay. The App Group must never store URL, DOM, screenshots, model payloads, or Hook state. An unsigned/ad-hoc structural build does not prove App Group access: the final Developer ID identity, registered App Group/provisioning choice, notarized bundle, and clean-install communication path require a real signed validation.

The native host also attaches the operating-system bundle identity of the browser process that launched it. The menu bar app rejects cross-browser responses and ambiguous multi-profile active-host results. Ambiguous Chromium sidebar geometry is handled only by the horizontal page DOM range expansion described above; it never permits browser-UI capture or cross-profile guessing.

## Reporting a vulnerability

Do not open a public issue containing sensitive reproduction data. Until a dedicated security contact is published, use GitHub’s private vulnerability reporting feature for this repository.
