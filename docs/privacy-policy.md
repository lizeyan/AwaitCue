# AwaitCue Privacy Policy

Effective date: October 27, 2026

AwaitCue is an open-source macOS menu bar app with Safari and Chromium browser extensions. Its single purpose is to observe an App region or the page content mapped from a browser region explicitly selected by the user, decide when the user-defined Condition is satisfied, and wait for an appropriate moment before returning that Target to the user's attention.

## Information AwaitCue processes

For a Target explicitly selected by the user, AwaitCue may process:

- the selected Safari or Chromium tab's URL, hostname, and title;
- a sanitized, length-bounded HTML fragment from the page DOM range mapped from the selected region, including relevant hierarchy, visible text, complete class values, ARIA and `data-*` attributes, and relative element coordinates;
- for ordinary macOS App Targets, a screenshot cropped to the selected window region;
- the user's Condition and limited decision results;
- the current visible screen context used to decide whether interruption is appropriate;
- a random extension installation identifier used to distinguish browser profiles.

Browser Targets are DOM-only. The Safari and Chromium extensions do not capture screenshots, tab video, canvas pixels, or image pixels. The local extractor selects content intersecting the mapped page range, removes unrelated or unsafe markup, and caps the fragment size. It does not interpret class names through a website-specific or business-status vocabulary; the user-configured model evaluates the sanitized HTML against the Condition. If a page exposes its state only through canvas or images and has no readable HTML meaning, AwaitCue treats the evidence as insufficient instead of falling back to a screenshot.

In Chromium layouts with left and/or right browser sidebars, the extension may be unable to determine the page viewport's exact horizontal origin. AwaitCue then expands the page DOM range horizontally to the smallest range covering every possible mapping of the selected rectangle. The resulting evidence may include page content immediately to the left or right of the rectangle. The creation window discloses this before the user confirms the Hook, and conflicting expanded evidence must produce an `uncertain` decision. This mapping never reads the address bar, tab strip, bookmarks bar, browser sidebar, or browser pixels because those surfaces are outside the page DOM.

AwaitCue does not use browser cookie, password, form-submission, web-request, clipboard, precise-location, financial-account, health-record, advertising, or browsing-history APIs.

## When processing starts and stops

Processing begins only after the user frames a Target and confirms a Hook. Processing stops when the Hook is completed or cancelled, the exact Target becomes unavailable, the extension disconnects, or the AwaitCue macOS app exits.

AwaitCue never automatically replaces a closed tab or window with another Target that merely has a similar title or URL.

## Local storage and retention

Ordinary-App screenshots, sanitized HTML evidence, frozen selection frames, and model request bodies are held in memory only and are not written to AwaitCue's local database or extension storage. Frozen selection frames are used locally to let the user draw the rectangle; a frame for a Browser Target is not included in browser evidence or sent to the model.

Each browser extension stores only a random installation identifier in extension-local storage. The macOS app stores Hook lifecycle metadata locally, stores the model API key in macOS Keychain, and stores the user's non-secret settings in macOS preferences. The Safari native extension and containing app share only a short-lived authenticated local-relay descriptor through their App Group; page content is not stored in the App Group.

AwaitCue does not enable telemetry or crash-report uploads in the current release.

## Model API selected by the user

The user configures an OpenAI Responses API-compatible endpoint. Before saving a new hostname, AwaitCue displays the exact hostname that will receive ordinary-App/current-screen screenshots and browser page information and requires explicit confirmation.

AwaitCue sends evidence only to that user-configured endpoint and sets `store: false` in model requests. The endpoint provider controls its own retention, access, and security practices; AwaitCue cannot guarantee that a third-party compatible endpoint honors `store: false`.

## Browser extension data transfer

The Chromium extension sends the mapped, sanitized page-HTML evidence only to the locally installed AwaitCue macOS companion through Chrome Native Messaging. When Chromium sidebar geometry is ambiguous, that mapped range may be horizontally expanded as described above. The Safari Web Extension sends the same DOM-only evidence through its embedded native app extension and an authenticated loopback relay. Neither extension sends network requests to an AwaitCue-operated server. The macOS companion may then send the evidence to the model hostname configured and confirmed by the user.

AwaitCue does not sell data or use it for advertising, credit decisions, profiling, or purposes unrelated to the Hook and interruption decisions described above.

## User controls and deletion

Users can stop processing by cancelling or completing a Hook, closing the bound Target, removing the extension, or quitting AwaitCue. The settings window can delete all local Hook data and the stored model API key. Removing the extension deletes its local installation identifier through the browser's normal extension-removal behavior.

Users can exclude configured app bundle identifiers and Safari/Chromium hosts from current-activity screenshots used for the interruption decision.

## Sensitive content

A selected region may visibly contain source code, messages, credentials, financial information, health information, or other sensitive content. Its sanitized HTML evidence can also include page class names and ARIA or `data-*` attribute values. In a Chromium layout with ambiguous sidebar geometry, the horizontally expanded DOM range may additionally include adjacent page content that was outside the visible rectangle. Users should not select a region when either it or nearby page content is sensitive unless their chosen model provider is permitted to receive that content.

## Chrome Web Store Limited Use

The use of information received from Google APIs will adhere to the Chrome Web Store User Data Policy, including the Limited Use requirements.

## Security and contact

Security issues should be reported through the repository's private vulnerability reporting page:

<https://github.com/lizeyan/AwaitCue/security/advisories/new>

General privacy questions can be opened as a non-sensitive repository issue. Do not include screenshots, API keys, page content, credentials, or other private reproduction data in a public issue.

The source code and current policy history are available at:

<https://github.com/lizeyan/AwaitCue>
