# AwaitCue Privacy Policy

Effective date: October 24, 2026

AwaitCue is an open-source macOS menu bar app and Chromium extension. Its single purpose is to observe a window or tab region explicitly selected by the user, decide when the user-defined Condition is satisfied, and wait for an appropriate moment before returning that Target to the user's attention.

## Information AwaitCue processes

For a Target explicitly selected by the user, AwaitCue may process:

- the selected Chromium tab's URL, hostname, and title;
- text and semantic attributes rendered inside the selected page region;
- screenshots or tab-capture frames cropped to the selected region;
- the user's Condition and limited decision results;
- the current visible screen context used to decide whether interruption is appropriate;
- a random extension installation identifier used to distinguish Chromium profiles.

AwaitCue does not use browser cookie, password, form-submission, web-request, clipboard, precise-location, financial-account, health-record, advertising, or browsing-history APIs.

## When processing starts and stops

Processing begins only after the user frames a Target and confirms a Hook. Browser pixel capture requires an additional click on the AwaitCue extension action. Processing stops when the Hook is completed or cancelled, the exact Target becomes unavailable, the extension disconnects, or the AwaitCue macOS app exits.

AwaitCue never automatically replaces a closed tab or window with another Target that merely has a similar title or URL.

## Local storage and retention

Screenshots, DOM evidence, frozen selection frames, and model request bodies are held in memory only and are not written to AwaitCue's local database or extension storage.

The Chromium extension stores only a random installation identifier in `chrome.storage.local`. The macOS app stores Hook lifecycle metadata locally, stores the model API key in macOS Keychain, and stores the user's non-secret settings in macOS preferences.

AwaitCue does not enable telemetry or crash-report uploads in the current release.

## Model API selected by the user

The user configures an OpenAI Responses API-compatible endpoint. Before saving a new hostname, AwaitCue displays the exact hostname that will receive screenshots and page information and requires explicit confirmation.

AwaitCue sends evidence only to that user-configured endpoint and sets `store: false` in model requests. The endpoint provider controls its own retention, access, and security practices; AwaitCue cannot guarantee that a third-party compatible endpoint honors `store: false`.

## Chromium extension data transfer

The extension sends selected-region evidence only to the locally installed AwaitCue macOS companion through Chrome Native Messaging. The extension does not send network requests to an AwaitCue-operated server. The macOS companion may then send the evidence to the model hostname configured and confirmed by the user.

AwaitCue does not sell data or use it for advertising, credit decisions, profiling, or purposes unrelated to the Hook and interruption decisions described above.

## User controls and deletion

Users can stop processing by cancelling or completing a Hook, closing the bound Target, removing the extension, or quitting AwaitCue. The settings window can delete all local Hook data and the stored model API key. Removing the extension deletes its local installation identifier through the browser's normal extension-removal behavior.

Users can exclude configured app bundle identifiers and Chromium hosts from current-activity screenshots used for the interruption decision.

## Sensitive content

A selected region may visibly contain source code, messages, credentials, financial information, health information, or other sensitive content. Users should not select sensitive regions unless their chosen model provider is permitted to receive that content.

## Chrome Web Store Limited Use

The use of information received from Google APIs will adhere to the Chrome Web Store User Data Policy, including the Limited Use requirements.

## Security and contact

Security issues should be reported through the repository's private vulnerability reporting page:

<https://github.com/lizeyan/AwaitCue/security/advisories/new>

General privacy questions can be opened as a non-sensitive repository issue. Do not include screenshots, API keys, page content, credentials, or other private reproduction data in a public issue.

The source code and current policy history are available at:

<https://github.com/lizeyan/AwaitCue>
