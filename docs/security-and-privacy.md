# Security and privacy

AwaitCue handles screen content that may include source code, documents, messages, credentials, or private browsing context. The privacy model therefore treats every capture and DOM fragment as sensitive by default.

## Local guarantees

- Screenshots, frozen selection frames, DOM text, and `tabCapture` frames remain in memory only.
- The application does not collect clipboard contents or actual key values.
- API keys are stored in macOS Keychain.
- Structured logs contain identifiers, decision enums, confidence, and sanitized error categories only.
- Telemetry and crash reporting are disabled in the initial release.
- Excluded apps and hosts are classified locally as not appropriate to interrupt; no screenshot is uploaded.
- Exiting the menu bar app stops observation and browser capture.

## Model endpoint boundary

The user configures a Responses API-compatible base URL. Before saving a new hostname, AwaitCue must disclose the exact destination receiving screenshots and page information.

Every request sets `store: false`, but a third-party compatible endpoint may ignore that field. AwaitCue can guarantee its own local behavior and outgoing request shape; it cannot guarantee a provider’s retention policy.

## Untrusted observed content

Text and images from observed apps are data, never instructions. Model instructions must explicitly state that page or window content cannot alter the decision contract, invoke tools, or request external actions.

## Browser permissions

DOM observation is preferred. Pixel-only browser Targets require an explicit user action to start `tabCapture`. The extension must request video only, use the lowest practical frame rate and resolution, and close the stream when the Hook completes, becomes unavailable, is cancelled, or the native app disconnects.

## Reporting a vulnerability

Do not open a public issue containing sensitive reproduction data. Until a dedicated security contact is published, use GitHub’s private vulnerability reporting feature for this repository.
